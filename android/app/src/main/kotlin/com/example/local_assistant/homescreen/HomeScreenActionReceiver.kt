package com.example.local_assistant.homescreen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * Кружок у задачи на виджете и будильник перерисовки (ADR-034). Только
 * свои PendingIntent: приёмник не экспортируется.
 *
 * «Выполнено» не пишет файл задач (его пишет только приложение — у
 * хранилища кэш в памяти): запись уходит в очередь
 * [HomeScreenStore.addDone], строка сразу зачёркнута, а через
 * [HomeScreenStore.LINGER] мс пропадает. Повторное нажатие в эти секунды
 * возвращает задачу.
 *
 * Приёмник отвечает сразу и не держит широковещательное намерение
 * (`goAsync`): система отдаёт такие намерения приёмнику из манифеста по
 * одному, и «вернуть» дождалось бы конца задержки — когда возвращать уже
 * нечего.
 */
class HomeScreenActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val now = HomeScreenStore.clock()
        when (intent.action) {
            ACTION_DONE -> {
                val task = intent.getStringExtra(EXTRA_TASK) ?: return
                val op = HomeScreenStore.addDone(context, task, now)
                HomeScreenWidgets.updateAll(context)
                if (op == null) return
                HomeScreenChannel.live?.notifyPending()
                // Через несколько секунд строка уходит: по таймеру, пока
                // процесс жив, а если его остановят — по будильнику
                // (HomeScreenStore.nextBoundary, его уже поставил updateAll).
                val app = context.applicationContext
                Handler(Looper.getMainLooper()).postDelayed(
                    { HomeScreenWidgets.updateAll(app) },
                    HomeScreenStore.LINGER + SETTLE_DELAY,
                )
            }
            ACTION_UNDO -> {
                val task = intent.getStringExtra(EXTRA_TASK) ?: return
                val op = HomeScreenStore.undo(context, task, now)
                HomeScreenWidgets.updateAll(context)
                if (op != null) HomeScreenChannel.live?.notifyPending()
            }
            ACTION_TICK -> HomeScreenWidgets.updateAll(context)
        }
    }

    companion object {
        const val ACTION_DONE = "com.example.local_assistant.homescreen.DONE"
        const val ACTION_UNDO = "com.example.local_assistant.homescreen.UNDO"
        const val ACTION_TICK = "com.example.local_assistant.homescreen.TICK"
        const val EXTRA_TASK = "task_id"

        /** Запас после показа отметки. */
        private const val SETTLE_DELAY = 300L
    }
}
