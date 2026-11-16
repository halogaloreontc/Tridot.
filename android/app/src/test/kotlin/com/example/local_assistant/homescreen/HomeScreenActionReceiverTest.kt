package com.example.local_assistant.homescreen

import android.Manifest
import android.app.AlarmManager
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.example.local_assistant.MainActivity
import com.example.local_assistant.notify.Reminder
import com.example.local_assistant.notify.ReminderReceiver
import com.example.local_assistant.notify.ReminderStore
import java.time.Duration
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Нажатия на виджете: отметка, отмена, напоминания и PendingIntent. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class HomeScreenActionReceiverTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private var clock = Fixtures.now

    @Before
    fun setUp() {
        HomeScreenStore.prefs(context).edit().clear().commit()
        ReminderStore.prefs(context).edit().clear().commit()
        HomeScreenStore.clock = { clock }
        val text = Fixtures.snapshot()
        HomeScreenStore.saveSnapshot(context, text, HsSnapshot.parse(text)!!, keep = true)
    }

    private fun bind(kind: HsKind, id: Int) {
        shadowOf(AppWidgetManager.getInstance(context)).bindAppWidgetId(id, kind.component(context))
    }

    @After
    fun tearDown() {
        HomeScreenStore.clock = { System.currentTimeMillis() }
    }

    /** Нажатие кружка: широковещательное намерение через систему. */
    private fun tap(action: String, task: String) {
        context.sendBroadcast(
            Intent(context, HomeScreenActionReceiver::class.java)
                .setAction(action)
                .putExtra(HomeScreenActionReceiver.EXTRA_TASK, task),
        )
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun scheduleReminder(task: String) {
        ReminderStore.replace(
            context,
            listOf(Reminder("r_$task", task, Fixtures.now + 3_600_000L, "Напоминание", "Связной")),
            emptySet(),
        )
    }

    private val notifications: NotificationManager
        get() = context.getSystemService(NotificationManager::class.java)

    /** Показанное напоминание задачи [task] (как у ReminderReceiver). */
    private fun showReminder(task: String) {
        notifications.notify(
            ReminderStore.notificationId(task),
            Notification.Builder(context, "test").setContentTitle("Напоминание").build(),
        )
    }

    private fun fire(task: String) {
        ReminderReceiver().onReceive(
            context,
            Intent(context, ReminderReceiver::class.java)
                .setAction(ReminderStore.ACTION_FIRE)
                .putExtra(ReminderStore.EXTRA_ID, "r_$task")
                .putExtra(ReminderStore.EXTRA_TASK, task)
                .putExtra(ReminderStore.EXTRA_TITLE, "Напоминание"),
        )
    }

    @Test
    fun doneQueuesOpAndQuietsTheTaskAfterLinger() {
        bind(HsKind.TODAY, 7)
        scheduleReminder("task_2")
        showReminder("task_2")
        tap(HomeScreenActionReceiver.ACTION_DONE, "task_2")
        assertEquals(listOf("done"), HomeScreenStore.ops(context).map { it.op })
        assertTrue(HomeScreenStore.isMarkedDone(context, "task_2"))
        // Пока строка видна зачёркнутой, всё на месте: можно вернуть.
        assertEquals(1, shadowOf(notifications).allNotifications.size)

        clock += HomeScreenStore.LINGER + 500L
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(HomeScreenStore.LINGER + 500L))
        // Показанное напоминание убрано, расписание — нет: его заменит
        // приложение, а до тех пор отметку проверяет ReminderReceiver.
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())
        assertEquals(listOf("r_task_2"), ReminderStore.load(context).map { it.id })
        assertTrue(HomeScreenStore.mark(context, "task_2")!!.settled)
        // Приложение ещё не подтвердило: строка спрятана, запись ждёт.
        assertTrue(HomeScreenStore.isMarkedDone(context, "task_2"))
        assertEquals(1, HomeScreenStore.ops(context).size)
        assertTrue(HomeScreenStore.board(context, clock).items.none { it.row.id == "task_2" })
    }

    @Test
    fun doneDoesNotHoldTheBroadcast() {
        // goAsync задержал бы следующее нажатие («вернуть») до конца показа.
        val receiver = HomeScreenActionReceiver()
        receiver.onReceive(
            context,
            Intent(context, HomeScreenActionReceiver::class.java)
                .setAction(HomeScreenActionReceiver.ACTION_DONE)
                .putExtra(HomeScreenActionReceiver.EXTRA_TASK, "task_2"),
        )
        assertTrue(HomeScreenStore.isMarkedDone(context, "task_2"))
        assertFalse(shadowOf(receiver).wentAsync())
    }

    @Test
    fun undoWithinLingerKeepsTheReminder() {
        bind(HsKind.COMBO, 9)
        scheduleReminder("task_2")
        tap(HomeScreenActionReceiver.ACTION_DONE, "task_2")
        clock += 2_000L
        tap(HomeScreenActionReceiver.ACTION_UNDO, "task_2")
        assertTrue(HomeScreenStore.ops(context).isEmpty())
        clock += 5_000L
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(5_000L))
        assertEquals(1, ReminderStore.load(context).size)
        assertFalse(HomeScreenStore.isMarkedDone(context, "task_2"))
    }

    @Test
    fun undoAfterTheOpenAppTookTheMarkReopensTheTask() {
        // Tridot открыт: отметку забрали и подтвердили через секунду, а
        // «вернуть» нажали на второй — до конца показа.
        bind(HsKind.TODAY, 7)
        scheduleReminder("task_2")
        val at = clock
        tap(HomeScreenActionReceiver.ACTION_DONE, "task_2")
        clock += 1_000L
        val taken = HomeScreenStore.pending(context)
        HomeScreenStore.ack(context, taken.last().seq)
        HomeScreenWidgets.updateAll(context)
        clock += 1_000L
        tap(HomeScreenActionReceiver.ACTION_UNDO, "task_2")
        val undo = HomeScreenStore.ops(context).single()
        assertEquals(HomeScreenStore.OP_UNDO, undo.op)
        assertEquals(at, undo.doneAt)
        assertFalse(HomeScreenStore.isMarkedDone(context, "task_2"))

        clock += 5_000L
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(5_000L))
        assertEquals(listOf("undo"), HomeScreenStore.ops(context).map { it.op })
        assertEquals(1, ReminderStore.load(context).size)
    }

    @Test
    fun lateUndoWithTheAppClosedLosesNothing() {
        // «Вернуть» пришло уже после конца показа (система задержала
        // намерение): задача возвращается вместе с напоминанием.
        bind(HsKind.TODAY, 7)
        scheduleReminder("task_2")
        tap(HomeScreenActionReceiver.ACTION_DONE, "task_2")
        clock += HomeScreenStore.LINGER + 500L
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(HomeScreenStore.LINGER + 500L))
        assertTrue(HomeScreenStore.mark(context, "task_2")!!.settled)

        tap(HomeScreenActionReceiver.ACTION_UNDO, "task_2")
        assertTrue(HomeScreenStore.ops(context).isEmpty())
        assertFalse(HomeScreenStore.isMarkedDone(context, "task_2"))
        assertEquals(listOf("r_task_2"), ReminderStore.load(context).map { it.id })
        assertTrue(HomeScreenStore.board(context, clock).items.any { it.row.id == "task_2" && !it.done })
    }

    @Test
    fun reminderOfAMarkedTaskIsNotShown() {
        shadowOf(context as Application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        tap(HomeScreenActionReceiver.ACTION_DONE, "task_1")
        fire("task_1")
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())
        clock += HomeScreenStore.LINGER + 1_500L
        fire("task_1")
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())
        assertTrue(ReminderStore.load(context).none { it.id == "r_task_1" })
    }

    @Test
    fun reminderDuringTheUndoWindowComesRightAfterIt() {
        shadowOf(context as Application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val at = clock
        tap(HomeScreenActionReceiver.ACTION_DONE, "task_1")
        clock += 1_000L
        fire("task_1")
        // Не показано, но и не забыто: отложено на конец показа.
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())
        val deferred = ReminderStore.load(context).single { it.id == "r_task_1" }
        assertTrue(deferred.at >= at + HomeScreenStore.LINGER)
        val alarms = context.getSystemService(AlarmManager::class.java)
        assertTrue(shadowOf(alarms).scheduledAlarms.any { it.triggerAtMs == deferred.at })

        clock += 1_000L
        tap(HomeScreenActionReceiver.ACTION_UNDO, "task_1")
        clock = deferred.at
        fire("task_1")
        assertEquals(1, shadowOf(notifications).allNotifications.size)
    }

    @Test
    fun renderingArmsTheTickAlarm() {
        bind(HsKind.TODAY, 7)
        HomeScreenWidgets.updateAll(context)
        val alarms = context.getSystemService(AlarmManager::class.java)
        val next = shadowOf(alarms).peekNextScheduledAlarm()
        assertNotNull(next)
        assertEquals(HomeScreenStore.nextMidnight(Fixtures.now), next!!.triggerAtMs)
        assertEquals(AlarmManager.RTC, next.getType())
    }

    @Test
    fun withoutATasksWidgetTheSnapshotIsForgotten() {
        bind(HsKind.QUICK, 8)
        assertEquals(
            mapOf(HsKind.TODAY to 0, HsKind.QUICK to 1, HsKind.COMBO to 0),
            HomeScreenWidgets.installed(context),
        )
        assertFalse(HomeScreenWidgets.hasTasksWidget(context))
        HomeScreenWidgets.forgetIfUnused(context)
        assertFalse(HomeScreenStore.hasSnapshot(context))
        HomeScreenWidgets.updateAll(context)
        val alarms = context.getSystemService(AlarmManager::class.java)
        assertNull(shadowOf(alarms).peekNextScheduledAlarm())
    }

    @Test
    fun pendingIntentsAreImmutableAndExplicit() {
        val open = shadowOf(HomeScreenIntents.openTask(context, "task_1"))
        assertTrue(open.isActivity)
        assertTrue(open.isImmutable)
        assertEquals(MainActivity::class.java.name, open.savedIntent.component?.className)
        assertEquals(HomeScreenIntents.ACTION_OPEN_TASK, open.savedIntent.action)
        assertEquals("task_1", open.savedIntent.getStringExtra(ReminderStore.EXTRA_TASK))
        assertNull(open.savedIntent.data)

        val done = shadowOf(HomeScreenIntents.done(context, "task_1"))
        assertTrue(done.isBroadcast)
        assertTrue(done.isImmutable)
        assertEquals(HomeScreenActionReceiver::class.java.name, done.savedIntent.component?.className)
        assertEquals("task_1", done.savedIntent.getStringExtra(HomeScreenActionReceiver.EXTRA_TASK))
        // Названия задач в намерениях нет.
        assertEquals(setOf(HomeScreenActionReceiver.EXTRA_TASK), done.savedIntent.extras!!.keySet())

        val compose = shadowOf(HomeScreenIntents.compose(context))
        assertEquals(HomeScreenIntents.ACTION_COMPOSE, compose.savedIntent.action)
        assertTrue(compose.isImmutable)
        val voice = shadowOf(HomeScreenIntents.voice(context))
        assertEquals(HomeScreenIntents.ACTION_VOICE, voice.savedIntent.action)
        assertTrue(voice.isImmutable)
        // Поле и микрофон — с ключом установки: чужое приложение его не знает.
        val key = HomeScreenStore.launchKey(context)
        assertEquals(32, key.length)
        assertEquals(key, compose.savedIntent.getStringExtra(HomeScreenIntents.EXTRA_KEY))
        assertEquals(key, voice.savedIntent.getStringExtra(HomeScreenIntents.EXTRA_KEY))
        assertEquals(key, HomeScreenStore.launchKey(context))

        // Две задачи — два разных PendingIntent, даже при одинаковом коде.
        assertFalse(HomeScreenIntents.openTask(context, "task_1") == HomeScreenIntents.openTask(context, "task_2"))
    }
}
