package com.example.local_assistant.homescreen

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
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
import org.robolectric.annotation.Config

/** Снимок, кадры по времени, очередь отметок и их показ на виджете. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class HomeScreenStoreTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val now = Fixtures.now

    @Before
    fun setUp() {
        HomeScreenStore.prefs(context).edit().clear().commit()
    }

    @After
    fun tearDown() {
        HomeScreenStore.clock = { System.currentTimeMillis() }
    }

    private fun save(text: String) {
        HomeScreenStore.saveSnapshot(context, text, HsSnapshot.parse(text)!!, keep = true)
    }

    @Test
    fun placeholderWithoutSnapshot() {
        val board = HomeScreenStore.board(context, now)
        assertEquals(HsBoard.State.PLACEHOLDER, board.state)
        assertTrue(board.voice)
    }

    @Test
    fun parsesRowsInOrderWithTableReferences() {
        save(Fixtures.snapshot())
        val board = HomeScreenStore.board(context, now)
        assertEquals(HsBoard.State.LIST, board.state)
        assertEquals(5, board.count)
        assertEquals(Fixtures.week.map { it.id }, board.items.map { it.row.id })
        val first = board.items[0].row
        assertTrue(first.overdue)
        assertEquals("вчера, просрочено", first.say)
        assertEquals("22 шт в ОК, 1 шт в уценке, арт. 67782", board.items[1].row.note)
        assertNull(board.items[0].row.note)
        assertFalse(board.items[5].row.counted)
    }

    @Test
    fun rejectsUnknownVersionAndGarbage() {
        assertNull(HsSnapshot.parse("{\"v\":2,\"frames\":[]}"))
        assertNull(HsSnapshot.parse("not json"))
    }

    @Test
    fun picksTheFrameByTime() {
        val all = Fixtures.week.take(2)
        val later = now + 3_600_000L
        val text = Fixtures.snapshot(
            tasks = all,
            frames = listOf(
                Fixtures.frame(0, all, all, count = 2),
                Fixtures.frame(later, all.take(1), all, count = 1),
            ),
        )
        save(text)
        assertEquals(2, HomeScreenStore.board(context, now).items.size)
        assertEquals(1, HomeScreenStore.board(context, later).items.size)
        assertEquals(later, HomeScreenStore.nextBoundary(context, now))
    }

    @Test
    fun nextBoundaryIsMidnightWithoutFrames() {
        save(Fixtures.snapshot())
        val boundary = HomeScreenStore.nextBoundary(context, now)
        assertEquals(HomeScreenStore.nextMidnight(now), boundary)
        assertEquals(14L * 3_600_000L, boundary - now)
    }

    @Test
    fun expiredAfterUntil() {
        save(Fixtures.snapshot(until = now + 1_000L))
        assertEquals(HsBoard.State.LIST, HomeScreenStore.board(context, now).state)
        assertEquals(now + 1_000L, HomeScreenStore.nextBoundary(context, now))
        assertEquals(HsBoard.State.EXPIRED, HomeScreenStore.board(context, now + 1_000L).state)
    }

    @Test
    fun countsModeHasNoTasks() {
        val text = Fixtures.snapshot(text = false, count = 3, summary = "3 дела")
        assertFalse(text.contains("Оплатить"))
        save(text)
        val board = HomeScreenStore.board(context, now)
        assertEquals(HsBoard.State.COUNTS, board.state)
        assertEquals(3, board.count)
        assertEquals("3 дела", board.summary)
        assertEquals("просрочена 1 задача", board.alert)
        assertTrue(board.items.isEmpty())
    }

    @Test
    fun snapshotIsKeptOnlyWithATasksWidgetButVoiceAlways() {
        val text = Fixtures.snapshot(voice = false)
        HomeScreenStore.saveSnapshot(context, text, HsSnapshot.parse(text)!!, keep = false)
        assertFalse(HomeScreenStore.hasSnapshot(context))
        assertFalse(HomeScreenStore.voice(context))
        assertEquals(HsBoard.State.PLACEHOLDER, HomeScreenStore.board(context, now).state)
    }

    @Test
    fun doneShowsCheckedRowInPlaceThenHidesIt() {
        save(Fixtures.snapshot())
        val op = HomeScreenStore.addDone(context, "task_2", now)
        assertNotNull(op)
        assertEquals(HomeScreenStore.OP_DONE, op!!.op)
        assertEquals(1L, op.seq)
        assertEquals(now, op.at)
        // Второе нажатие той же строки (старый вид) ничего не добавляет.
        assertNull(HomeScreenStore.addDone(context, "task_2", now + 10))

        val lingering = HomeScreenStore.board(context, now + 1_000L)
        assertEquals(4, lingering.count)
        assertEquals("task_2", lingering.items[1].row.id)
        assertTrue(lingering.items[1].done)
        assertEquals(7, lingering.items.size)
        assertEquals(now + HomeScreenStore.LINGER, HomeScreenStore.nextBoundary(context, now + 1_000L))

        val after = HomeScreenStore.board(context, now + HomeScreenStore.LINGER)
        assertEquals(6, after.items.size)
        assertTrue(after.items.none { it.row.id == "task_2" })
        assertEquals(4, after.count)
        assertTrue(HomeScreenStore.isMarkedDone(context, "task_2"))
    }

    @Test
    fun unknownTaskIsIgnored() {
        save(Fixtures.snapshot())
        assertNull(HomeScreenStore.addDone(context, "task_gone", now))
        assertTrue(HomeScreenStore.ops(context).isEmpty())
    }

    @Test
    fun undoBeforeTheAppReadItRemovesTheOp() {
        save(Fixtures.snapshot())
        HomeScreenStore.addDone(context, "task_1", now)
        assertNull(HomeScreenStore.undo(context, "task_1", now + 2_000L))
        assertTrue(HomeScreenStore.ops(context).isEmpty())
        assertFalse(HomeScreenStore.isMarkedDone(context, "task_1"))
        assertEquals(5, HomeScreenStore.board(context, now + 2_000L).count)
    }

    @Test
    fun undoAfterTheAppReadItQueuesUndo() {
        save(Fixtures.snapshot())
        HomeScreenStore.addDone(context, "task_1", now)
        assertEquals(1, HomeScreenStore.pending(context).size)
        val undo = HomeScreenStore.undo(context, "task_1", now + 2_000L)
        assertNotNull(undo)
        assertEquals(HomeScreenStore.OP_UNDO, undo!!.op)
        assertEquals(2L, undo.seq)
        assertEquals(now, undo.doneAt)
        val queue = HomeScreenStore.pending(context).map { it.toMap() }
        assertEquals(listOf("done", "undo"), queue.map { it["op"] })
        assertEquals(now, queue[1]["doneAt"])
        assertFalse(queue[0].containsKey("doneAt"))
    }

    @Test
    fun ackRemovesAppliedOpsAndMarksAfterLinger() {
        save(Fixtures.snapshot())
        HomeScreenStore.addDone(context, "task_1", now)
        HomeScreenStore.addDone(context, "task_3", now + 500L)
        HomeScreenStore.pending(context)
        HomeScreenStore.ack(context, 1L)
        assertEquals(listOf(2L), HomeScreenStore.ops(context).map { it.seq })

        val settled = mutableListOf<String>()
        HomeScreenStore.settle(context, now + 1_000L) { settled.add(it) }
        // Ещё показываются — напоминания не трогаем.
        assertTrue(settled.isEmpty())
        assertEquals(2, HomeScreenStore.marks(context).size)

        HomeScreenStore.settle(context, now + 10_000L) { settled.add(it) }
        assertEquals(setOf("task_1", "task_3"), settled.toSet())
        // Подтверждена только первая: вторая ещё прячет строку.
        assertEquals(setOf("task_3"), HomeScreenStore.marks(context).keys)
        HomeScreenStore.settle(context, now + 20_000L) { settled.add(it) }
        assertEquals(2, settled.size)

        // Приложение пропустило отметку (задачу правили позже): строка
        // возвращается, когда отметка подтверждена.
        HomeScreenStore.ack(context, 2L)
        HomeScreenStore.settle(context, now + 30_000L) { settled.add(it) }
        assertTrue(HomeScreenStore.marks(context).isEmpty())
        assertTrue(HomeScreenStore.board(context, now + 30_000L).items.any { it.row.id == "task_3" })
    }

    @Test
    fun opsSurviveAsJson() {
        save(Fixtures.snapshot())
        HomeScreenStore.addDone(context, "task_4", now)
        val raw = HomeScreenStore.prefs(context).getString("ops", null)!!
        val first = org.json.JSONArray(raw).getJSONObject(0)
        assertEquals("task_4", first.getString("task"))
        // Названий в очереди нет — только id и время.
        assertFalse(raw.contains("Забрать"))
        assertTrue(JSONObject(HomeScreenStore.prefs(context).getString("marks", "{}")!!).has("task_4"))
    }
}
