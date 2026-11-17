package com.example.local_assistant.homescreen

import java.util.Calendar
import org.json.JSONArray
import org.json.JSONObject

/** Вымышленные дела для тестов виджетов: как снимок из приложения. */
object Fixtures {
    data class Task(
        val id: String,
        val title: String,
        val due: String,
        val overdue: Boolean = false,
        val counted: Boolean = true,
        val note: String? = null,
    )

    val week = listOf(
        Task("task_1", "Оплатить интернет", "вчера", overdue = true),
        Task("task_2", "Сдать реестр по складу", "11:00", note = "22 шт в ОК, 1 шт в уценке, арт. 67782"),
        Task("task_3", "Позвонить в стоматологию и записаться на чистку на следующей неделе", "вечером"),
        Task("task_4", "Забрать посылку на почте", "без времени"),
        Task("task_5", "Купить корм коту", "без времени", note = "Тот же, что в прошлый раз"),
        Task("task_6", "Отправить отчёт", "завтра в 10:00", counted = false),
        Task("task_7", "Продлить страховку", "20 ноября", counted = false),
    )

    /** 16 ноября 2026, 10:00 по часам устройства. */
    val now: Long = Calendar.getInstance().run {
        clear()
        set(2026, Calendar.NOVEMBER, 16, 10, 0)
        timeInMillis
    }

    fun frame(
        from: Long,
        tasks: List<Task>,
        all: List<Task>,
        count: Int = tasks.count { it.counted },
        summary: String = "$count дел",
        alert: String? = null,
    ): JSONObject = JSONObject()
        .put("from", from)
        .put("count", count)
        .put("summary", summary)
        .put("alert", alert ?: JSONObject.NULL)
        .put(
            "rows",
            JSONArray().apply {
                tasks.forEach { task ->
                    put(
                        JSONObject()
                            .put("t", all.indexOf(task))
                            .put("due", task.due)
                            .put("overdue", task.overdue)
                            .put("counted", task.counted)
                            .apply { if (task.overdue) put("say", "${task.due}, просрочено") },
                    )
                }
            },
        )

    fun snapshot(
        tasks: List<Task> = week,
        text: Boolean = true,
        voice: Boolean = true,
        until: Long? = null,
        count: Int = tasks.count { it.counted },
        summary: String = "$count дел",
        alert: String? = "просрочена 1 задача",
        frames: List<JSONObject>? = null,
    ): String = JSONObject()
        .put("v", 1)
        .put("mode", if (text) "text" else "counts")
        .put("voice", voice)
        .put("until", until ?: JSONObject.NULL)
        .put(
            "tasks",
            JSONArray().apply {
                if (text) {
                    tasks.forEach {
                        put(
                            JSONObject()
                                .put("id", it.id)
                                .put("title", it.title)
                                .put("note", it.note ?: JSONObject.NULL),
                        )
                    }
                }
            },
        )
        .put(
            "frames",
            JSONArray().apply {
                (frames ?: listOf(frame(0, if (text) tasks else emptyList(), tasks, count, summary, alert)))
                    .forEach { put(it) }
            },
        )
        .toString()
}
