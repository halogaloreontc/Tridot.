package com.example.local_assistant.homescreen

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Build
import com.example.local_assistant.MainActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Канал `tridot/homescreen` (ADR-034). Договор — в начале
 * lib/app/homescreen/home_screen_channel.dart. Приложение отдаёт снимок
 * «Сегодня» (строкой JSON) и забирает очередь отметок; Android говорит,
 * что нажали поле или микрофон, что в очереди новая запись и что виджету
 * нужен снимок.
 *
 * Нажатие поля или микрофона — одноразовое: прочитанное намерение
 * заменяется пустым (как в IncomingLinkChannel), а запуск из «Недавних»
 * (FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) и восстановление после остановки
 * процесса ([restored]: система снова приносит намерение, которым задачу
 * когда-то открыли) его не повторяют — иначе микрофон включался бы при
 * возврате в приложение. Без ключа установки (HomeScreenIntents.EXTRA_KEY)
 * нажатие не принимается: его прислал не наш виджет.
 */
class HomeScreenChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
    /** Активность восстановлена из сохранённого состояния. */
    private val restored: Boolean = false,
) {
    private val channel = MethodChannel(messenger, NAME)

    /** Чем открыли приложение (холодный запуск с виджета). */
    private var launch: String? = null

    init {
        launch = read(activity.intent, stale = restored)
        channel.setMethodCallHandler(::handle)
        live = this
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> result.success(state())
            "sync" -> {
                val text = call.arguments as? String
                val snapshot = text?.let(HsSnapshot::parse)
                if (text == null || snapshot == null) {
                    result.error("bad_snapshot", "snapshot is not a v1 JSON string", null)
                    return
                }
                HomeScreenStore.saveSnapshot(
                    activity,
                    text,
                    snapshot,
                    keep = HomeScreenWidgets.hasTasksWidget(activity),
                )
                HomeScreenWidgets.updateAll(activity)
                result.success(null)
            }
            "pending" -> result.success(HomeScreenStore.pending(activity).map { it.toMap() })
            "ack" -> {
                val upTo = (call.argument<Any>("upTo") as? Number)?.toLong()
                if (upTo != null) {
                    HomeScreenStore.ack(activity, upTo)
                    HomeScreenWidgets.updateAll(activity)
                }
                result.success(null)
            }
            "pin" -> result.success(pin(HsKind.of(call.argument<String>("kind"))))
            "takeLaunch" -> {
                result.success(launch)
                launch = null
            }
            else -> result.notImplemented()
        }
    }

    private fun state(): Map<String, Any> {
        val installed = HomeScreenWidgets.installed(activity)
        val tasks = installed.filterKeys { it.tasks }.values.sum()
        return mapOf(
            "supported" to true,
            "canPin" to canPin(),
            "installed" to installed.mapKeys { it.key.key },
            "needsSnapshot" to (tasks > 0 && !HomeScreenStore.hasSnapshot(activity)),
        )
    }

    private fun manager(): AppWidgetManager? = AppWidgetManager.getInstance(activity)

    private fun canPin(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager()?.isRequestPinAppWidgetSupported == true

    private fun pin(kind: HsKind?): Boolean {
        if (kind == null || !canPin()) return false
        return try {
            manager()?.requestPinAppWidget(kind.component(activity), null, null) == true
        } catch (error: IllegalStateException) {
            false
        }
    }

    /** Новое намерение, пока приложение открыто. `true` — оно наше. */
    fun onNewIntent(intent: Intent): Boolean {
        val what = read(intent) ?: return false
        channel.invokeMethod("launch", what)
        return true
    }

    /** Поле или микрофон из [intent]; [stale] — намерение прежнего запуска. */
    private fun read(intent: Intent?, stale: Boolean = false): String? {
        if (intent == null) return null
        val what = when (intent.action) {
            HomeScreenIntents.ACTION_COMPOSE -> "compose"
            HomeScreenIntents.ACTION_VOICE -> "voice"
            else -> return null
        }
        val key = intent.getStringExtra(HomeScreenIntents.EXTRA_KEY)
        // Одноразово: из намерения убираем сразу.
        intent.action = Intent.ACTION_MAIN
        intent.removeExtra(HomeScreenIntents.EXTRA_KEY)
        if (intent === activity.intent) {
            activity.intent = Intent(activity, MainActivity::class.java)
        }
        if (stale || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        if (!HomeScreenIntents.trusted(activity, key)) return null
        return what
    }

    /** В очереди отметок новая запись. */
    fun notifyPending() {
        channel.invokeMethod("pendingChanged", null)
    }

    /** Виджет с задачами поставили, снимка нет. */
    fun needSnapshot() {
        channel.invokeMethod("needSnapshot", null)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (live === this) live = null
    }

    companion object {
        const val NAME = "tridot/homescreen"

        /** Канал работающего приложения (движок Flutter жив) или `null`. */
        @Volatile
        var live: HomeScreenChannel? = null
            private set
    }
}
