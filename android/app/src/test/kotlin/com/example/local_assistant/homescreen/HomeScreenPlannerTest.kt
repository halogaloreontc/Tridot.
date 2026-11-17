package com.example.local_assistant.homescreen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Сколько строк «Сегодня» помещается: только целиком, строки раньше «ещё N», записи сверху. */
class HomeScreenPlannerTest {
    private val heights = HsHeights(row = 44f, rowNote = 56f, empty = 40f, more = 28f)

    private fun item(
        id: String,
        counted: Boolean = true,
        note: String? = null,
        done: Boolean = false,
    ) = HsItem(HsRow(id, id, note, "11:00", false, counted, null), done)

    private fun tasks(plan: HsPlan) = plan.lines.filterIsInstance<HsPlan.Line.Task>()

    @Test
    fun allFitWithoutMore() {
        val items = (1..4).map { item("t$it") }
        val plan = HomeScreenPlanner.plan(items, 4, room = 176f, heights, narrow = false)
        assertEquals(4, tasks(plan).size)
        assertEquals(0, plan.more)
    }

    @Test
    fun hiddenTasksGoToMoreAndNeverCut() {
        val items = (1..6).map { item("t$it") }
        // 4 строки — 176, «ещё 2» (28) под ними помещается: 204.
        val plan = HomeScreenPlanner.plan(items, 6, room = 204f, heights, narrow = false)
        assertEquals(4, tasks(plan).size)
        assertEquals(2, plan.more)
    }

    @Test
    fun rowsComeBeforeMore() {
        val items = (1..6).map { item("t$it") }
        // 4 строки — 176, «ещё 2» уже не влезает (204 > 190): строка ради
        // него не пропадает, число дел и так в шапке.
        val plan = HomeScreenPlanner.plan(items, 6, room = 190f, heights, narrow = false)
        assertEquals(4, tasks(plan).size)
        assertEquals(0, plan.more)
    }

    @Test
    fun moreCountsOnlyTodayAndOverdue() {
        val items = listOf(item("a"), item("b"), item("later", counted = false))
        val plan = HomeScreenPlanner.plan(items, 2, room = 100f, heights, narrow = false)
        // Две задачи на сегодня поместились, ближайшая — нет: «ещё» не нужно.
        assertEquals(2, tasks(plan).size)
        assertEquals(0, plan.more)
    }

    @Test
    fun moreIncludesTasksBeyondTheSnapshotRows() {
        val items = (1..2).map { item("t$it") }
        val plan = HomeScreenPlanner.plan(items, 15, room = 400f, heights, narrow = false)
        assertEquals(2, tasks(plan).size)
        assertEquals(13, plan.more)
    }

    @Test
    fun notesTopDownOnlyWhileNoTaskIsLost() {
        val items = listOf(item("a", note = "n"), item("b", note = "n"), item("c", note = "n"))
        // 3 × 44 = 132; места 160: хватает на две записи (+12 каждая), третья — нет.
        val plan = HomeScreenPlanner.plan(items, 3, room = 160f, heights, narrow = false)
        val lines = tasks(plan)
        assertEquals(3, lines.size)
        assertEquals(listOf(true, true, false), lines.map { it.note })
        val roomy = HomeScreenPlanner.plan(items, 3, room = 400f, heights, narrow = false)
        assertTrue(tasks(roomy).all { it.note })
    }

    @Test
    fun noNotesWhenTasksAreHidden() {
        val items = (1..6).map { item("t$it", note = "n") }
        val plan = HomeScreenPlanner.plan(items, 6, room = 190f, heights, narrow = false)
        assertTrue(tasks(plan).none { it.note })
    }

    @Test
    fun narrowRowsAreTwoLinesWithoutNotes() {
        val items = (1..4).map { item("t$it", note = "n") }
        val plan = HomeScreenPlanner.plan(items, 4, room = 196f, heights, narrow = true)
        // 56 на строку: три строки (168) + «ещё 1» (28) = 196.
        assertEquals(3, tasks(plan).size)
        assertEquals(1, plan.more)
        assertTrue(tasks(plan).none { it.note })
    }

    @Test
    fun nothingTodayButUpcomingStartsWithEmptyLine() {
        val items = listOf(item("later1", counted = false), item("later2", counted = false))
        val plan = HomeScreenPlanner.plan(items, 0, room = 200f, heights, narrow = false)
        assertEquals(HsPlan.Line.Empty, plan.lines.first())
        assertEquals(2, tasks(plan).size)
        assertEquals(0, plan.more)
    }

    @Test
    fun justDoneRowKeepsItsPlaceAndIsNotCounted() {
        val items = listOf(item("a"), item("b", done = true, note = "n"), item("c"))
        val plan = HomeScreenPlanner.plan(items, 2, room = 132f, heights, narrow = false)
        assertEquals(listOf(0, 1, 2), tasks(plan).map { it.item })
        assertEquals(0, plan.more)
        assertTrue(tasks(plan).none { it.note })
    }

    @Test
    fun tooSmallShowsNothing() {
        val plan = HomeScreenPlanner.plan(listOf(item("a")), 1, room = 20f, heights, narrow = false)
        assertTrue(plan.lines.isEmpty())
        assertEquals(0, plan.more)
    }

    @Test
    fun neverOnlyMore() {
        // «ещё 2» поместилось бы, строка — нет: пусто, число дел — в шапке.
        val plan = HomeScreenPlanner.plan(listOf(item("a"), item("b")), 2, room = 30f, heights, narrow = false)
        assertTrue(plan.lines.isEmpty())
        assertEquals(0, plan.more)
    }

    @Test
    fun oneRowWithoutMoreWhenTheyDoNotFitTogether() {
        // Самый низкий «Сегодня»: строка (44) есть, строки и «ещё» (72) — нет.
        val items = (1..5).map { item("t$it") }
        val plan = HomeScreenPlanner.plan(items, 5, room = 70f, heights, narrow = false)
        assertEquals(listOf(0), tasks(plan).map { it.item })
        assertEquals(0, plan.more)
        assertTrue(tasks(plan).none { it.note })
        // Хватает на строку и «ещё» — как обычно.
        val roomier = HomeScreenPlanner.plan(items, 5, room = 72f, heights, narrow = false)
        assertEquals(1, tasks(roomier).size)
        assertEquals(4, roomier.more)
    }
}
