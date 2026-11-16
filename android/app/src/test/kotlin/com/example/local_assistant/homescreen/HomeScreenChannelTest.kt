package com.example.local_assistant.homescreen

import android.app.Activity
import android.app.Application
import android.appwidget.AppWidgetManager
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.example.local_assistant.notify.NotifyChannel
import com.example.local_assistant.notify.ReminderStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Канал `tridot/homescreen` по договору из home_screen_channel.dart. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class HomeScreenChannelTest {
    /** Мессенджер Flutter без движка: вызовы как из Dart, ответы и события — сюда. */
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        val events = mutableListOf<MethodCall>()

        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.rewind()
            events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message))
            callback?.reply(null)
        }

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            handlers[channel] = handler
        }

        fun call(method: String, arguments: Any? = null, channel: String = HomeScreenChannel.NAME): Any? {
            val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments))
            message.rewind()
            var answer: Any? = null
            handlers[channel]!!.onMessage(message) { reply ->
                reply!!.rewind()
                // Первый байт конверта: 0 — ответ, 1 — ошибка.
                // Ответ null — [0, 0]: decodeEnvelope помечен как не-null.
                answer = when {
                    reply.get(0).toInt() == 1 -> ERROR
                    reply.limit() == 2 && reply.get(1).toInt() == 0 -> null
                    else -> StandardMethodCodec.INSTANCE.decodeEnvelope(reply)
                }
            }
            return answer
        }

        companion object {
            val ERROR = Any()
        }
    }

    private val context: Application = ApplicationProvider.getApplicationContext()
    private val messenger = Messenger()
    private var channel: HomeScreenChannel? = null

    @Before
    fun setUp() {
        HomeScreenStore.prefs(context).edit().clear().commit()
        HomeScreenStore.clock = { Fixtures.now }
    }

    @After
    fun tearDown() {
        channel?.dispose()
        HomeScreenStore.clock = { System.currentTimeMillis() }
    }

    private fun open(intent: Intent = Intent(Intent.ACTION_MAIN), restored: Boolean = false): Activity {
        val activity = Robolectric.buildActivity(Activity::class.java, intent).get()
        channel = HomeScreenChannel(activity, messenger, restored)
        return activity
    }

    /** Намерение поля или микрофона, как в PendingIntent виджета (с ключом). */
    private fun widget(action: String): Intent = HomeScreenIntents.keyed(context, action)

    private fun bind(kind: HsKind, id: Int) {
        shadowOf(AppWidgetManager.getInstance(context)).bindAppWidgetId(id, kind.component(context))
    }

    @Test
    fun coldLaunchFromTheFieldIsOneShot() {
        val activity = open(widget(HomeScreenIntents.ACTION_COMPOSE))
        assertEquals("compose", messenger.call("takeLaunch"))
        assertNull(messenger.call("takeLaunch"))
        // Намерение активности заменено: поворот в том же процессе его не повторит.
        assertFalse(activity.intent.action == HomeScreenIntents.ACTION_COMPOSE)
    }

    @Test
    fun launchFromRecentsDoesNotRestartTheMicrophone() {
        open(widget(HomeScreenIntents.ACTION_VOICE).addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY))
        assertNull(messenger.call("takeLaunch"))
    }

    @Test
    fun restoreAfterProcessDeathDoesNotRestartTheMicrophone() {
        // Процесс остановили в фоне; из «Недавних» или по значку система
        // пересоздаёт активность с исходным намерением и сохранённым
        // состоянием, без FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY.
        val activity = open(widget(HomeScreenIntents.ACTION_VOICE), restored = true)
        assertNull(messenger.call("takeLaunch"))
        assertFalse(activity.intent.action == HomeScreenIntents.ACTION_VOICE)
        // Новое нажатие на виджете после этого — как обычно.
        assertTrue(channel!!.onNewIntent(widget(HomeScreenIntents.ACTION_VOICE)))
        assertEquals("voice", messenger.events.single().arguments)
    }

    @Test
    fun launchWithoutTheInstallKeyIsIgnored() {
        // Другое приложение (до Android 14 оно может прислать явное намерение).
        open(Intent(HomeScreenIntents.ACTION_VOICE))
        assertNull(messenger.call("takeLaunch"))
        assertFalse(
            channel!!.onNewIntent(
                Intent(HomeScreenIntents.ACTION_VOICE).putExtra(HomeScreenIntents.EXTRA_KEY, "0".repeat(32)),
            ),
        )
        assertFalse(channel!!.onNewIntent(Intent(HomeScreenIntents.ACTION_COMPOSE)))
        assertTrue(messenger.events.isEmpty())
    }

    @Test
    fun taskFromAWidgetRowIsOneShotAndNotReplayedAfterRestore() {
        fun notify(intent: Intent, restored: Boolean): Any? {
            val activity = Robolectric.buildActivity(Activity::class.java, intent).get()
            NotifyChannel(activity, messenger, restored)
            return messenger.call("takeLaunchTask", channel = NotifyChannel.NAME)
        }
        val row = { Intent(HomeScreenIntents.ACTION_OPEN_TASK).putExtra(ReminderStore.EXTRA_TASK, "task_1") }
        assertEquals("task_1", notify(row(), restored = false))
        assertNull(notify(row(), restored = true))
        assertNull(notify(row().addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY), restored = false))
    }

    @Test
    fun warmLaunchIsAnEvent() {
        open()
        assertTrue(channel!!.onNewIntent(widget(HomeScreenIntents.ACTION_VOICE)))
        assertEquals("launch", messenger.events.single().method)
        assertEquals("voice", messenger.events.single().arguments)
        // Строка задачи — не наше: её открывает tridot/notify.
        assertFalse(
            channel!!.onNewIntent(
                Intent(HomeScreenIntents.ACTION_OPEN_TASK).putExtra(ReminderStore.EXTRA_TASK, "task_1"),
            ),
        )
    }

    @Test
    fun stateReportsWidgetsAndMissingSnapshot() {
        open()
        bind(HsKind.TODAY, 3)
        bind(HsKind.QUICK, 4)
        shadowOf(AppWidgetManager.getInstance(context)).setRequestPinAppWidgetSupported(true)
        val state = messenger.call("state") as Map<*, *>
        assertEquals(true, state["supported"])
        assertEquals(true, state["canPin"])
        assertEquals(mapOf("today" to 1, "quick" to 1, "combo" to 0), state["installed"])
        assertEquals(true, state["needsSnapshot"])
        messenger.call("sync", Fixtures.snapshot())
        assertEquals(false, (messenger.call("state") as Map<*, *>)["needsSnapshot"])
    }

    @Test
    fun snapshotIsStoredOnlyWhileATasksWidgetExists() {
        open()
        messenger.call("sync", Fixtures.snapshot(voice = false))
        assertFalse(HomeScreenStore.hasSnapshot(context))
        assertFalse(HomeScreenStore.voice(context))
        bind(HsKind.COMBO, 5)
        messenger.call("sync", Fixtures.snapshot())
        assertTrue(HomeScreenStore.hasSnapshot(context))
        assertTrue(HomeScreenStore.voice(context))
    }

    @Test
    fun badSnapshotIsAnError() {
        open()
        bind(HsKind.TODAY, 2)
        assertTrue(messenger.call("sync", "{\"v\": 9}") === Messenger.ERROR)
        assertTrue(messenger.call("sync", 42) === Messenger.ERROR)
        assertFalse(HomeScreenStore.hasSnapshot(context))
    }

    @Test
    fun pendingThenAck() {
        open()
        bind(HsKind.TODAY, 6)
        messenger.call("sync", Fixtures.snapshot())
        HomeScreenStore.addDone(context, "task_3", Fixtures.now)
        val pending = messenger.call("pending") as List<*>
        val op = pending.single() as Map<*, *>
        assertEquals("done", op["op"])
        assertEquals("task_3", op["task"])
        assertEquals(1, (op["seq"] as Number).toInt())
        assertEquals(Fixtures.now, (op["at"] as Number).toLong())
        messenger.call("ack", mapOf("upTo" to 1))
        assertEquals(emptyList<Any>(), messenger.call("pending"))
    }

    @Test
    fun pinAsksTheLauncher() {
        open()
        val shadow = shadowOf(AppWidgetManager.getInstance(context))
        shadow.setRequestPinAppWidgetSupported(false)
        assertEquals(false, messenger.call("pin", mapOf("kind" to "today")))
        shadow.setRequestPinAppWidgetSupported(true)
        assertEquals(true, messenger.call("pin", mapOf("kind" to "quick")))
        assertEquals(false, messenger.call("pin", mapOf("kind" to "warehouse")))
    }

    @Test
    fun liveChannelSignalsTheApp() {
        open()
        assertTrue(HomeScreenChannel.live === channel)
        HomeScreenChannel.live!!.notifyPending()
        HomeScreenChannel.live!!.needSnapshot()
        assertEquals(listOf("pendingChanged", "needSnapshot"), messenger.events.map { it.method })
        channel!!.dispose()
        assertNull(HomeScreenChannel.live)
        channel = null
    }
}
