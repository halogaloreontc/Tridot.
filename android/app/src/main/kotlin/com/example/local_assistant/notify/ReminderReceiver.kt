package com.example.local_assistant.notify

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.example.local_assistant.MainActivity
import com.example.local_assistant.R
import com.example.local_assistant.homescreen.HomeScreenStore

/**
 * Пришло время напоминания (ADR-029): уведомление в канале «Напоминания».
 * На заблокированном экране — только «Напоминание из Tridot», название
 * задачи видно после разблокировки. Нажатие открывает чат задачи;
 * «Через 10 минут» переставляет то же напоминание.
 */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(ReminderStore.EXTRA_ID) ?: return
        val taskId = intent.getStringExtra(ReminderStore.EXTRA_TASK) ?: return
        val title = intent.getStringExtra(ReminderStore.EXTRA_TITLE) ?: return
        val persona = intent.getStringExtra(ReminderStore.EXTRA_PERSONA) ?: ""
        val reminder = Reminder(id, taskId, System.currentTimeMillis(), title, persona)
        // Задачу уже отметили выполненной на виджете (ADR-034), а
        // приложение ещё не прислало новое расписание: не напоминать. В
        // первые секунды отметку ещё могут вернуть — тогда напоминание
        // придёт сразу после них. «Через 10 минут» просто откладывается:
        // через 10 минут проверка будет та же.
        val mark = HomeScreenStore.mark(context, taskId)
        if (mark != null && intent.action != ReminderStore.ACTION_SNOOZE) {
            val now = HomeScreenStore.clock()
            val end = mark.at + HomeScreenStore.LINGER
            if (!mark.settled && now >= mark.at && now < end) {
                ReminderStore.defer(context, reminder.copy(at = end + DEFER_SLACK))
                return
            }
            ReminderStore.forget(context, id)
            ReminderStore.dismiss(context, taskId)
            return
        }
        when (intent.action) {
            ReminderStore.ACTION_SNOOZE -> {
                NotificationManagerCompat.from(context).cancel(notificationId(taskId))
                ReminderStore.snooze(context, reminder)
            }
            else -> {
                ReminderStore.forget(context, id)
                show(context, reminder)
            }
        }
    }

    private fun notificationId(taskId: String) = ReminderStore.notificationId(taskId)

    private companion object {
        /** Запас после показа отметки на виджете. */
        const val DEFER_SLACK = 1_000L
    }

    private fun show(context: Context, reminder: Reminder) {
        NotifyChannel.ensureChannels(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val open = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(ReminderStore.EXTRA_TASK, reminder.taskId)
        val content = PendingIntent.getActivity(
            context,
            reminder.requestCode,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val snooze = PendingIntent.getBroadcast(
            context,
            reminder.requestCode + 1,
            Intent(context, ReminderReceiver::class.java)
                .setAction(ReminderStore.ACTION_SNOOZE)
                .putExtra(ReminderStore.EXTRA_ID, reminder.id)
                .putExtra(ReminderStore.EXTRA_TASK, reminder.taskId)
                .putExtra(ReminderStore.EXTRA_TITLE, reminder.title)
                .putExtra(ReminderStore.EXTRA_PERSONA, reminder.persona),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val header = if (reminder.persona.isBlank()) {
            "Напоминание"
        } else {
            "${reminder.persona} · напоминание"
        }
        val public = NotificationCompat.Builder(context, NotifyChannel.REMINDERS)
            .setSmallIcon(R.drawable.ic_stat_tridot)
            .setContentTitle("Напоминание из Tridot")
            .build()
        val notification = NotificationCompat.Builder(context, NotifyChannel.REMINDERS)
            .setSmallIcon(R.drawable.ic_stat_tridot)
            .setContentTitle(header)
            .setContentText(reminder.title)
            .setStyle(NotificationCompat.BigTextStyle().bigText(reminder.title))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setAutoCancel(true)
            .setContentIntent(content)
            .addAction(0, "Через 10 минут", snooze)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(notificationId(reminder.taskId), notification)
        } catch (error: SecurityException) {
            // Разрешение отозвали между проверкой и показом.
        }
    }
}
