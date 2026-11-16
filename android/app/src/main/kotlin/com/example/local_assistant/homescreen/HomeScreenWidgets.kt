package com.example.local_assistant.homescreen

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import com.example.local_assistant.MainActivity
import java.security.MessageDigest
import com.example.local_assistant.notify.ReminderStore

/** Вид виджета; [key] — имя в канале `tridot/homescreen`. */
enum class HsKind(
    val key: String,
    val provider: Class<out AppWidgetProvider>,
    /** Показывает задачи: нужен снимок. */
    val tasks: Boolean,
    /** Размер, если лаунчер его не сообщил (minWidth/minHeight в res/xml). */
    val fallback: SizeF,
) {
    TODAY("today", TodayWidget::class.java, true, SizeF(250f, 110f)),
    QUICK("quick", QuickWidget::class.java, false, SizeF(250f, 48f)),
    COMBO("combo", ComboWidget::class.java, true, SizeF(250f, 180f));

    fun component(context: Context) = ComponentName(context, provider)

    companion object {
        fun of(key: String?): HsKind? = entries.firstOrNull { it.key == key }
    }
}

/**
 * Виджеты рабочего стола (ADR-034). Перерисовываются при новом снимке из
 * приложения, при добавлении и смене размера, после отметки, по
 * будильнику на начало следующего кадра или полночь и после
 * перезагрузки, обновления и смены времени (notify/BootReceiver.kt).
 */
abstract class HomeScreenProvider(private val kind: HsKind) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        HomeScreenWidgets.render(context, kind, ids)
        if (kind.tasks) HomeScreenWidgets.askSnapshot(context)
        HomeScreenWidgets.arm(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        options: Bundle?,
    ) {
        HomeScreenWidgets.render(context, kind, intArrayOf(id))
    }

    override fun onDisabled(context: Context) {
        HomeScreenWidgets.forgetIfUnused(context)
    }
}

/** «Сегодня»: ближайшие и просроченные задачи. */
class TodayWidget : HomeScreenProvider(HsKind.TODAY)

/** «Быстрый ввод»: «Что сделать?» и микрофон. */
class QuickWidget : HomeScreenProvider(HsKind.QUICK)

/** «Сегодня и ввод». */
class ComboWidget : HomeScreenProvider(HsKind.COMBO)

object HomeScreenWidgets {
    /** Окно перерисовки по будильнику без точного времени (Android 12+ — не меньше 10 минут). */
    private const val WINDOW = 10 * 60_000L

    fun ids(context: Context, kind: HsKind): IntArray = try {
        AppWidgetManager.getInstance(context)?.getAppWidgetIds(kind.component(context))
            ?: IntArray(0)
    } catch (error: RuntimeException) {
        IntArray(0)
    }

    fun installed(context: Context): Map<HsKind, Int> =
        HsKind.entries.associateWith { ids(context, it).size }

    /** Стоит «Сегодня» или «Сегодня и ввод». */
    fun hasTasksWidget(context: Context): Boolean =
        HsKind.entries.any { it.tasks && ids(context, it).isNotEmpty() }

    /** Перерисовать все виджеты и переставить будильник. */
    fun updateAll(context: Context) {
        val now = HomeScreenStore.clock()
        settle(context, now)
        val board = HomeScreenStore.board(context, now)
        HsKind.entries.forEach { draw(context, it, ids(context, it), board, now) }
        arm(context)
    }

    /** Перерисовать виджеты [ids] вида [kind] (добавили, сменили размер). */
    fun render(context: Context, kind: HsKind, ids: IntArray) {
        if (ids.isEmpty()) return
        val now = HomeScreenStore.clock()
        settle(context, now)
        draw(context, kind, ids, HomeScreenStore.board(context, now), now)
    }

    /** Кончился показ отметки: убрать показанное напоминание задачи (ADR-029). */
    private fun settle(context: Context, now: Long) {
        HomeScreenStore.settle(context, now) { ReminderStore.dismiss(context, it) }
    }

    private fun draw(context: Context, kind: HsKind, ids: IntArray, board: HsBoard, now: Long) {
        if (ids.isEmpty()) return
        val manager = AppWidgetManager.getInstance(context) ?: return
        val metrics = HomeScreenRenderer.Metrics(context)
        ids.forEach { id ->
            val views = HomeScreenRenderer.build(
                context,
                kind,
                board,
                manager.getAppWidgetOptions(id),
                now,
                metrics,
            )
            manager.updateAppWidget(id, views)
        }
    }

    /** Виджет с задачами поставили, а снимка нет: попросить у приложения, если оно открыто. */
    fun askSnapshot(context: Context) {
        if (!HomeScreenStore.hasSnapshot(context)) HomeScreenChannel.live?.needSnapshot()
    }

    /** Убрали последний виджет с задачами: снимок больше не храним. */
    fun forgetIfUnused(context: Context) {
        if (!hasTasksWidget(context)) {
            HomeScreenStore.clearSnapshot(context)
            cancelTick(context)
        }
    }

    /**
     * Будильник на следующую перемену вида (кадр, полночь, конец показа
     * отметки). Не будит телефон: сработает, когда экран включат. С
     * «Будильниками и напоминаниями» (их и так просят для напоминаний) —
     * точно в срок, без них — в течение 10 минут.
     */
    fun arm(context: Context) {
        if (!hasTasksWidget(context)) {
            cancelTick(context)
            return
        }
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val at = HomeScreenStore.nextBoundary(context, HomeScreenStore.clock())
        val tick = tick(context, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        try {
            if (ReminderStore.canExact(context)) {
                alarms.setExact(AlarmManager.RTC, at, tick)
            } else {
                alarms.setWindow(AlarmManager.RTC, at, WINDOW, tick)
            }
        } catch (error: SecurityException) {
            alarms.set(AlarmManager.RTC, at, tick)
        }
    }

    private fun cancelTick(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val tick = tick(context, PendingIntent.FLAG_NO_CREATE) ?: return
        alarms.cancel(tick)
        tick.cancel()
    }

    private fun tick(context: Context, flags: Int): PendingIntent? = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, HomeScreenActionReceiver::class.java)
            .setAction(HomeScreenActionReceiver.ACTION_TICK),
        flags or PendingIntent.FLAG_IMMUTABLE,
    )
}

/**
 * Нажатия на виджете. Все PendingIntent неизменяемые и с явным
 * получателем. Действия — свои, не ACTION_VIEW и без адреса `tridot:`:
 * IncomingLinkChannel принял бы его за ссылку склада, а нажатие
 * уведомления (ACTION_VIEW) не путается с нажатием строки.
 *
 * Поле и микрофон несут ключ установки ([EXTRA_KEY]): активность
 * экспортирована, и до Android 14 любое приложение могло бы прислать
 * `…VOICE` и включить микрофон. Ключ лежит в PendingIntent виджета,
 * другим приложениям его не прочитать.
 */
object HomeScreenIntents {
    const val ACTION_OPEN_TASK = "com.example.local_assistant.homescreen.OPEN_TASK"
    const val ACTION_COMPOSE = "com.example.local_assistant.homescreen.COMPOSE"
    const val ACTION_VOICE = "com.example.local_assistant.homescreen.VOICE"
    const val EXTRA_KEY = "homescreen_key"

    private const val FLAGS = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    private const val REQUEST_APP = 0
    private const val REQUEST_COMPOSE = 1
    private const val REQUEST_VOICE = 2

    /** Шапка, «ещё N», сообщения: приложение выходит вперёд как есть. */
    fun app(context: Context): PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(context, REQUEST_APP, intent, FLAGS)
    }

    /** «Что сделать?»: поле ввода с клавиатурой. */
    fun compose(context: Context): PendingIntent =
        PendingIntent.getActivity(context, REQUEST_COMPOSE, keyed(context, ACTION_COMPOSE), FLAGS)

    /** Микрофон: сразу голосовой ввод. */
    fun voice(context: Context): PendingIntent =
        PendingIntent.getActivity(context, REQUEST_VOICE, keyed(context, ACTION_VOICE), FLAGS)

    /** Намерение поля или микрофона с ключом установки. */
    fun keyed(context: Context, action: String): Intent =
        activity(context, action).putExtra(EXTRA_KEY, HomeScreenStore.launchKey(context))

    /** Ключ из намерения совпал с ключом установки. */
    fun trusted(context: Context, key: String?): Boolean {
        if (key.isNullOrEmpty()) return false
        return MessageDigest.isEqual(
            key.toByteArray(),
            HomeScreenStore.launchKey(context).toByteArray(),
        )
    }

    /** Строка задачи: её чат — тем же путём, что нажатие напоминания (`tridot/notify`). */
    fun openTask(context: Context, taskId: String): PendingIntent {
        val intent = activity(context, ACTION_OPEN_TASK)
            .putExtra(ReminderStore.EXTRA_TASK, taskId)
        distinct(intent, taskId)
        return PendingIntent.getActivity(context, taskId.hashCode(), intent, FLAGS)
    }

    fun done(context: Context, taskId: String): PendingIntent =
        broadcast(context, HomeScreenActionReceiver.ACTION_DONE, taskId)

    fun undo(context: Context, taskId: String): PendingIntent =
        broadcast(context, HomeScreenActionReceiver.ACTION_UNDO, taskId)

    private fun activity(context: Context, action: String): Intent =
        Intent(context, MainActivity::class.java)
            .setAction(action)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    private fun broadcast(context: Context, action: String, taskId: String): PendingIntent {
        val intent = Intent(context, HomeScreenActionReceiver::class.java)
            .setAction(action)
            .putExtra(HomeScreenActionReceiver.EXTRA_TASK, taskId)
        distinct(intent, taskId)
        return PendingIntent.getBroadcast(context, taskId.hashCode(), intent, FLAGS)
    }

    /**
     * Свой PendingIntent на каждую задачу: дополнительные данные в
     * сравнение не входят, а совпадение кода у двух задач открыло бы не
     * тот чат. С Android 10 — по идентификатору намерения.
     */
    private fun distinct(intent: Intent, taskId: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) intent.identifier = taskId
    }
}
