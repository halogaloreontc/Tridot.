package com.example.local_assistant.notify

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.AlarmClock
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Канал `tridot/notify` (ADR-029): разрешение на уведомления, точное время,
 * расписание напоминаний о задачах и будильник / таймер в «Часах».
 *
 * Ничего не уходит в сеть. Системе отдаётся только расписание (название
 * задачи, время, имя помощника). Будильник ставит не Tridot, а «Часы»:
 * открываются с заполненным будильником, человек подтверждает там
 * (EXTRA_SKIP_UI = false). USE_EXACT_ALARM не запрашивается: Google Play
 * разрешает его только будильникам и календарям.
 */
class NotifyChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
    /** Активность восстановлена из сохранённого состояния (MainActivity). */
    restored: Boolean = false,
) {
    private val channel = MethodChannel(messenger, NAME)
    private var pendingRequest: MethodChannel.Result? = null

    /** Задача из уведомления, которым открыли приложение. */
    private var launchTask: String? = null

    init {
        channel.setMethodCallHandler(::handle)
        ensureChannels(activity)
        launchTask = takeTask(activity.intent, stale = restored)
        // Расписание могло потеряться (приложение остановили из настроек).
        ReminderStore.reschedule(activity)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "request" -> request(result)
            "exactStatus" -> result.success(exactStatus())
            "openNotificationSettings" -> {
                openNotificationSettings()
                result.success(null)
            }
            "openExactAlarmSettings" -> {
                openExactAlarmSettings()
                result.success(null)
            }
            "sync" -> {
                val args = call.arguments as? Map<*, *>
                val list = (args?.get("reminders") as? List<*>).orEmpty()
                    .mapNotNull { (it as? Map<*, *>)?.let(Reminder::fromMap) }
                val snoozable = (args?.get("snoozable") as? List<*>).orEmpty()
                    .mapNotNull { it as? String }
                    .toSet()
                ReminderStore.replace(activity, list, snoozable)
                result.success(null)
            }
            "canSetAlarm" -> result.success(canSetAlarm())
            "setAlarm" -> result.success(setAlarm(call))
            "setTimer" -> result.success(setTimer(call))
            "takeLaunchTask" -> {
                result.success(launchTask)
                launchTask = null
            }
            else -> result.notImplemented()
        }
    }

    private fun granted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun status(): String {
        if (!granted()) {
            val asked = ReminderStore.prefs(activity).getInt(ReminderStore.ASKED, 0)
            return when {
                asked == 0 -> "notAsked"
                ActivityCompat.shouldShowRequestPermissionRationale(
                    activity,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) -> "denied"
                else -> "permanentlyDenied"
            }
        }
        // Android до 13 или разрешение есть, но уведомления выключены в
        // настройках — вернуть можно только там.
        if (!NotificationManagerCompat.from(activity).areNotificationsEnabled()) {
            return "permanentlyDenied"
        }
        if (channelOff()) return "permanentlyDenied"
        return "granted"
    }

    private fun channelOff(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = activity.getSystemService(NotificationManager::class.java) ?: return false
        val reminders = manager.getNotificationChannel(REMINDERS) ?: return false
        return reminders.importance == NotificationManager.IMPORTANCE_NONE
    }

    private fun request(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || granted()) {
            result.success(status())
            return
        }
        pendingRequest?.success(status())
        pendingRequest = result
        val prefs = ReminderStore.prefs(activity)
        prefs.edit().putInt(ReminderStore.ASKED, prefs.getInt(ReminderStore.ASKED, 0) + 1).apply()
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE,
        )
    }

    /** Ответ на системный вопрос — из MainActivity. `true` — наш вопрос. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pendingRequest?.success(status())
        pendingRequest = null
        if (granted()) ReminderStore.reschedule(activity)
        return true
    }

    /** Нажато уведомление или строка виджета, пока приложение открыто. */
    fun onNewIntent(intent: Intent) {
        val taskId = takeTask(intent) ?: return
        channel.invokeMethod("openTask", taskId)
    }

    /**
     * Задача из уведомления или строки виджета — один раз: из намерения
     * она убирается. Запуск из «Недавних» и восстановление после
     * остановки процесса ([stale]) приносят прежнее намерение заново — его
     * не читаем, иначе чат задачи открывался бы при каждом возврате в
     * приложение.
     */
    private fun takeTask(intent: Intent?, stale: Boolean = false): String? {
        if (intent == null) return null
        val taskId = intent.getStringExtra(ReminderStore.EXTRA_TASK) ?: return null
        intent.removeExtra(ReminderStore.EXTRA_TASK)
        if (stale || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return taskId
    }

    private fun exactStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return "notNeeded"
        return if (ReminderStore.canExact(activity)) "granted" else "denied"
    }

    private fun start(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (error: ActivityNotFoundException) {
        false
    } catch (error: SecurityException) {
        false
    }

    private fun openNotificationSettings() {
        val pkg = activity.packageName
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = if (granted() &&
                NotificationManagerCompat.from(activity).areNotificationsEnabled() &&
                channelOff()
            ) {
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, pkg)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, REMINDERS)
            } else {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, pkg)
            }
            if (start(intent)) return
        }
        start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")))
    }

    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val pkg = activity.packageName
        if (!start(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$pkg")))) {
            start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")))
        }
    }

    private fun canSetAlarm(): Boolean =
        Intent(AlarmClock.ACTION_SET_ALARM).resolveActivity(activity.packageManager) != null

    private fun setAlarm(call: MethodCall): Boolean {
        val hour = call.argument<Int>("hour") ?: return false
        val minute = call.argument<Int>("minute") ?: return false
        if (hour !in 0..23 || minute !in 0..59) return false
        val intent = Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, hour)
            .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, false)
        call.argument<String>("label")?.take(40)?.let {
            intent.putExtra(AlarmClock.EXTRA_MESSAGE, it)
        }
        val days = call.argument<List<Int>>("days").orEmpty().filter { it in 1..7 }
        if (days.isNotEmpty()) {
            // 1 — понедельник … 7 — воскресенье → Calendar.SUNDAY = 1 …
            intent.putExtra(AlarmClock.EXTRA_DAYS, ArrayList(days.map { it % 7 + 1 }))
        }
        return start(intent)
    }

    private fun setTimer(call: MethodCall): Boolean {
        val seconds = call.argument<Int>("seconds") ?: return false
        if (seconds !in 1..86400) return false
        val intent = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, false)
        call.argument<String>("label")?.take(40)?.let {
            intent.putExtra(AlarmClock.EXTRA_MESSAGE, it)
        }
        return start(intent)
    }

    companion object {
        const val NAME = "tridot/notify"
        const val REMINDERS = "reminders"
        const val ALERTS = "alerts"
        private const val REQUEST_CODE = 4101

        /** Каналы «Напоминания» и «Оповещения» (Android 8+). */
        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(REMINDERS) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(REMINDERS, "Напоминания", NotificationManager.IMPORTANCE_HIGH)
                        .apply { description = "Задачи, у которых наступил срок" },
                )
            }
            if (manager.getNotificationChannel(ALERTS) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(ALERTS, "Оповещения", NotificationManager.IMPORTANCE_DEFAULT)
                        .apply { description = "Итоги долгих задач расширений" },
                )
            }
        }
    }
}
