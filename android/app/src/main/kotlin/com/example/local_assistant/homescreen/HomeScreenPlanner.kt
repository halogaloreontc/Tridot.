package com.example.local_assistant.homescreen

/**
 * Высоты строк виджета в dp при текущем масштабе шрифта (считает
 * [HomeScreenRenderer.Metrics] по шрифту телефона). Совпадают с макетами
 * res/layout/hw_*.xml: строка растёт вместе с текстом и не бывает ниже
 * 48 dp.
 */
data class HsHeights(
    /** Строка задачи в одну строку текста. */
    val row: Float,
    /** Строка с последней записью (или на узком виджете — со сроком) под названием. */
    val rowNote: Float,
    /** «На сегодня дел нет» над ближайшими задачами. */
    val empty: Float,
    /** «ещё N». */
    val more: Float,
)

/** Что поместилось: строки по порядку и сколько дел осталось за «ещё N». */
data class HsPlan(val lines: List<Line>, val more: Int) {
    sealed interface Line {
        /** Задача [item] из [HsBoard.items]; [note] — с записью под названием. */
        data class Task(val item: Int, val note: Boolean) : Line

        /** «На сегодня дел нет» — дальше только ближайшие задачи. */
        data object Empty : Line
    }
}

/**
 * Сколько строк «Сегодня» помещается целиком (ADR-034). Ни одной
 * обрезанной строки. Сначала строки задач — сколько помещается; что не
 * поместилось, считает число дел в шапке, а под строками, если хватает
 * места, ещё и «ещё N» (только дела на сегодня и просроченные — ближайшие
 * задачи на свободных строках не считаются). Ради «ещё N» строка не
 * пропадает, а без строк его не бывает. Записи под названием — только
 * когда видны все дела на сегодня, сверху вниз и пока от них не
 * пропадает ни одна строка. На узком виджете ([narrow]) срок стоит под
 * названием, записей нет.
 */
object HomeScreenPlanner {
    fun plan(
        items: List<HsItem>,
        count: Int,
        room: Float,
        heights: HsHeights,
        narrow: Boolean,
    ): HsPlan {
        val lines = mutableListOf<HsPlan.Line>()
        val firstUpcoming = items.indexOfFirst { !it.done && !it.row.counted }
        items.indices.forEach { index ->
            if (count == 0 && index == firstUpcoming) lines.add(HsPlan.Line.Empty)
            lines.add(HsPlan.Line.Task(index, note = false))
        }

        fun height(line: HsPlan.Line): Float = when (line) {
            HsPlan.Line.Empty -> heights.empty
            is HsPlan.Line.Task -> {
                val item = items[line.item]
                if (narrow && !item.done) heights.rowNote else heights.row
            }
        }

        fun shownCounted(k: Int): Int = lines.take(k).count {
            it is HsPlan.Line.Task && !items[it.item].done && items[it.item].row.counted
        }

        // Сначала строки — сколько помещается целиком.
        var fit = 0
        var used = 0f
        while (fit < lines.size && used + height(lines[fit]) <= room) {
            used += height(lines[fit])
            fit++
        }
        val shown = lines.take(fit).toMutableList()
        val hidden = (count - shownCounted(fit)).coerceAtLeast(0)
        // «ещё N» — только под строками и если помещается: строка задачи
        // важнее, а число дел и так в шапке.
        val more = if (hidden > 0 && fit > 0 && used + heights.more <= room) hidden else 0
        // Записи — только когда видны все дела на сегодня: сначала задачи.
        if (!narrow && hidden == 0) {
            val extra = heights.rowNote - heights.row
            shown.indices.forEach { index ->
                val line = shown[index]
                if (line is HsPlan.Line.Task) {
                    val item = items[line.item]
                    if (!item.done && item.row.note != null && used + extra <= room) {
                        shown[index] = line.copy(note = true)
                        used += extra
                    }
                }
            }
        }
        return HsPlan(shown, more)
    }
}
