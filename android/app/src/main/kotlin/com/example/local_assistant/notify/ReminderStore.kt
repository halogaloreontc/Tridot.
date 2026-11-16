package com.example.local_assistant.notify

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Расписание напоминаний о задачах (ADR-029): только название задачи,
 * время и имя помощника. Лежит в SharedPreferences `tridot_reminders` —
 * они исключены из резервной копии (res/xml/data_extraction_rules.xml,
 * backup_rules.xml): это производные данные, план строится заново из задач.
 * Никуда не отправляется.
 */
data class Reminder(
    val id: String,
    val taskId: String,
    val at: Long,
    val title: String,
    val persona: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("taskId", taskId)
        .put("at", at)
        .put("title", title)
        .put("persona", persona)

    /** Код PendingIntent: из id напоминания, одинаковый между запусками. */
    val requestCode: Int get() = id.hashCode()

    companion object {
        fun fromJson(json: JSONObject): Reminder? = try {
            Reminder(
                id = json.getString("id"),
                taskId = json.getString("taskId"),
                at = json.getLong("at"),
                title = json.getString("title").take(200),
                persona = json.optString("persona", "").take(40),
            )
        } catch (error: Exception) {
            null
        }

        fun fromMap(map: Map<*, *>): Reminder? {
            val id = map["id"] as? String ?: return null
            val taskId = map["taskId"] as? String ?: return null
            val at = (map["at"] as? Number)?.toLong() ?: return null
            val title = map["title"] as? String ?: return null
            val persona = map["persona"] as? String ?: ""
            return Reminder(id, taskId, at, title.take(200), persona.take(40))
        }
    }
}

object ReminderStore {
    const val PREFS = "tridot_reminders"
    private const val KEY = "plan"

    /** Сколько раз спрашивали POST_NOTIFICATIONS (для «ещё не спрашивали»). */
    const val ASKED = "asked"

    const val EXTRA_ID = "reminder_id"
    const val EXTRA_TASK = "task_id"
    const val EXTRA_TITLE = "title"
    const val EXTRA_PERSONA = "persona"
    const val ACTION_FIRE = "com.example.local_assistant.REMINDER"
    const val ACTION_SNOOZE = "com.example.local_assistant.REMINDER_SNOOZE"

    /** Не больше стольких напоминаний: тот же предел, что в Dart. */
    private const val MAX = 50

    fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(context: Context): List<Reminder> {
        val text = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(text)
            (0 until array.length()).mapNotNull { Reminder.fromJson(array.getJSONObject(it)) }
        } catch (error: Exception) {
            emptyList()
        }
    }

    private fun save(context: Context, reminders: List<Reminder>) {
        val array = JSONArray()
        reminders.forEach { array.put(it.toJson()) }
        prefs(context).edit().putString(KEY, array.toString()).apply()
    }

    /** Отложенное «Через 10 минут»: у Dart такого id нет. */
    private const val SNOOZE = "+snooze"

    /** Сработавшие без телефона не дольше этого срока показываются сразу. */
    private const val OVERDUE_WINDOW = 12 * 60 * 60_000L

    /**
     * Заменяет всё расписание: старые будильники снимаются. Отложенные
     * («Через 10 минут») остаются, пока их задача в [snoozable] — Dart не
     * знает о них, и без этого откладывание терялось при первой синхронизации.
     */
    fun replace(context: Context, reminders: List<Reminder>, snoozable: Set<String>) {
        val now = System.currentTimeMillis()
        val old = load(context)
        val incoming = reminders.take(MAX)
        val ids = incoming.map { it.id }.toSet()
        val snoozed = old.filter {
            it.id.endsWith(SNOOZE) && it.at > now && it.taskId in snoozable && it.id !in ids
        }
        old.filter { it !in snoozed }.forEach { cancel(context, it) }
        val next = incoming + snoozed
        save(context, next)
        scheduleAll(context, incoming)
    }

    /**
     * Заново ставит сохранённое расписание (загрузка, смена времени).
     * Пропущенные, пока телефон был выключен, — не позже 12 часов назад —
     * показываются сразу, а не теряются.
     */
    fun reschedule(context: Context) {
        val now = System.currentTimeMillis()
        val kept = load(context).filter { it.at > now - OVERDUE_WINDOW }
        val (overdue, upcoming) = kept.partition { it.at <= now }
        val due = overdue.mapIndexed { index, it -> it.copy(at = now + 5_000L + index * 1_000L) }
        val next = upcoming + due
        save(context, next)
        scheduleAll(context, next)
    }

    /** Номер уведомления задачи: одно на задачу, как у ReminderReceiver. */
    fun notificationId(taskId: String): Int = taskId.hashCode()

    /**
     * Задачу отметили выполненной на виджете (ADR-034) и показ отметки
     * кончился: показанное уведомление убирается. Расписание остаётся —
     * отметку можно вернуть; пока она есть, ReminderReceiver напоминание
     * не показывает, а приложение потом пришлёт расписание без задачи.
     */
    fun dismiss(context: Context, taskId: String) {
        NotificationManagerCompat.from(context).cancel(notificationId(taskId))
    }

    /**
     * То же напоминание позже — в `reminder.at`, не раньше: задачу только
     * что отметили на виджете, и её ещё могут вернуть (ADR-034).
     */
    fun defer(context: Context, reminder: Reminder) {
        save(context, load(context).filter { it.id != reminder.id } + reminder)
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = pending(context, reminder, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        try {
            if (canExact(context)) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, intent)
            } else {
                alarms.setWindow(AlarmManager.RTC_WAKEUP, reminder.at, 10 * 60_000L, intent)
            }
        } catch (error: SecurityException) {
            alarms.set(AlarmManager.RTC_WAKEUP, reminder.at, intent)
        }
    }

    /** Убирает показанное напоминание из расписания. */
    fun forget(context: Context, id: String) {
        save(context, load(context).filter { it.id != id })
    }

    /** «Через 10 минут»: то же напоминание позже. */
    fun snooze(context: Context, reminder: Reminder) {
        val later = reminder.copy(
            id = reminder.id + "+snooze",
            at = System.currentTimeMillis() + 10 * 60_000L,
        )
        val rest = load(context).filter { it.id != later.id && it.id != reminder.id }
        save(context, rest + later)
        schedule(context, later)
    }

    private fun scheduleAll(context: Context, reminders: List<Reminder>) {
        val now = System.currentTimeMillis()
        reminders.filter { it.at > now }.forEach { schedule(context, it) }
    }

    private fun pending(context: Context, reminder: Reminder, flags: Int): PendingIntent? {
        val intent = Intent(context, ReminderReceiver::class.java)
            .setAction(ACTION_FIRE)
            .putExtra(EXTRA_ID, reminder.id)
            .putExtra(EXTRA_TASK, reminder.taskId)
            .putExtra(EXTRA_TITLE, reminder.title)
            .putExtra(EXTRA_PERSONA, reminder.persona)
        return PendingIntent.getBroadcast(
            context,
            reminder.requestCode,
            intent,
            flags or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun canExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return false
        return alarms.canScheduleExactAlarms()
    }

    private fun schedule(context: Context, reminder: Reminder) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = pending(context, reminder, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        try {
            if (canExact(context)) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, intent)
            } else {
                // Без «Будильников и напоминаний» — окно ±10 минут.
                alarms.setWindow(
                    AlarmManager.RTC_WAKEUP,
                    reminder.at - 10 * 60_000L,
                    20 * 60_000L,
                    intent,
                )
            }
        } catch (error: SecurityException) {
            alarms.set(AlarmManager.RTC_WAKEUP, reminder.at, intent)
        }
    }

    private fun cancel(context: Context, reminder: Reminder) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = pending(context, reminder, PendingIntent.FLAG_NO_CREATE) ?: return
        alarms.cancel(intent)
        intent.cancel()
    }
}
