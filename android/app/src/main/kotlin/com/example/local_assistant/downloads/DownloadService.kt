package com.example.local_assistant.downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.example.local_assistant.MainActivity
import com.example.local_assistant.R

/**
 * Загрузка моделей в фоне (ADR-046): служба переднего плана, пока Dart
 * скачивает модель. Сама ничего не качает — только держит процесс живым,
 * когда приложение свёрнуто, и показывает ход в уведомлении. Тип —
 * dataSync.
 */
class DownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stop()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Скачивается модель"
        val received = intent?.getLongExtra(EXTRA_RECEIVED, 0) ?: 0
        val total = intent?.getLongExtra(EXTRA_TOTAL, 0) ?: 0
        val notification = build(title, received, total)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, notification)
        }
        // Процесс убит — загрузку продолжит приложение при следующем
        // запуске (продолжение с места), служба сама не перезапускается.
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15: dataSync ограничен по времени — уходим сами.
        stop()
    }

    private fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun build(title: String, received: Long, total: Long): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CHANNEL) == null
        ) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Загрузки", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "Модели, которые скачиваются в фоне" },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val known = total > 0
        val percent = if (known) (received * 100 / total).toInt().coerceIn(0, 100) else 0
        return builder
            .setSmallIcon(R.drawable.ic_stat_tridot)
            .setContentTitle(title)
            .setContentText(
                if (known) "${received / 1_000_000} из ${total / 1_000_000} МБ" else "Подготовка…",
            )
            .setProgress(100, percent, !known)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .build()
    }

    companion object {
        const val ACTION_STOP = "tridot.downloads.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_RECEIVED = "received"
        const val EXTRA_TOTAL = "total"
        private const val CHANNEL = "downloads"
        private const val ID = 4201

        fun update(context: Context, title: String, received: Long, total: Long) {
            val intent = Intent(context, DownloadService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_RECEIVED, received)
                .putExtra(EXTRA_TOTAL, total)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, DownloadService::class.java).setAction(ACTION_STOP),
            )
        }
    }
}
