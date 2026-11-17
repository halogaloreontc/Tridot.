package com.example.local_assistant.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.example.local_assistant.homescreen.HomeScreenWidgets

/**
 * Перезагрузка, обновление приложения, смена времени или часового пояса,
 * выдали или отозвали «Будильники и напоминания»: будильники Android
 * теряются или смещаются — расписание ставится заново из
 * `tridot_reminders` (ADR-029), а виджеты рабочего стола (ADR-034)
 * перерисовываются по часам и заново ставят свой будильник.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED",
            -> {
                ReminderStore.reschedule(context)
                HomeScreenWidgets.updateAll(context)
            }
        }
    }
}
