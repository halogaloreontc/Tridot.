package com.example.local_assistant.homescreen

import android.content.Context
import android.content.SharedPreferences
import java.security.SecureRandom
import java.util.Calendar
import org.json.JSONArray
import org.json.JSONObject

/**
 * Строка «Сегодня» из снимка: задача и готовая подпись её срока. Слова
 * приходят из приложения (lib/core/homescreen/home_screen_snapshot.dart),
 * здесь ничего не склоняется.
 */
data class HsRow(
    val id: String,
    val title: String,
    val note: String?,
    val due: String,
    val overdue: Boolean,
    val counted: Boolean,
    val say: String?,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("title", title)
        .put("note", note ?: JSONObject.NULL)
        .put("due", due)
        .put("overdue", overdue)
        .put("counted", counted)
        .put("say", say ?: JSONObject.NULL)

    companion object {
        fun fromJson(json: JSONObject): HsRow? = try {
            HsRow(
                id = json.getString("id"),
                title = json.getString("title").take(MAX_TEXT),
                note = json.optText("note")?.take(MAX_TEXT),
                due = json.optString("due", "").take(MAX_DUE),
                overdue = json.optBoolean("overdue", false),
                counted = json.optBoolean("counted", false),
                say = json.optText("say")?.take(MAX_DUE),
            )
        } catch (error: Exception) {
            null
        }
    }
}

/** Кадр: вид «Сегодня» с [from] до начала следующего кадра. */
data class HsFrame(
    val from: Long,
    val count: Int,
    val summary: String,
    val alert: String?,
    val rows: List<HsRow>,
)

/** Снимок из приложения (договор — lib/app/homescreen/home_screen_channel.dart). */
data class HsSnapshot(
    val text: Boolean,
    val voice: Boolean,
    val until: Long?,
    val frames: List<HsFrame>,
) {
    /** Кадр на момент [now]: последний с началом не позже него. */
    fun frameAt(now: Long): HsFrame? =
        frames.lastOrNull { it.from <= now } ?: frames.firstOrNull()

    /** Начало следующего кадра после [now]; `null` — дальше кадров нет. */
    fun nextFrom(now: Long): Long? = frames.firstOrNull { it.from > now }?.from

    companion object {
        fun parse(text: String): HsSnapshot? = try {
            val json = JSONObject(text)
            if (json.optInt("v", 0) != 1) {
                null
            } else {
                val table = json.optJSONArray("tasks") ?: JSONArray()
                val tasks = (0 until table.length()).map { index ->
                    val task = table.getJSONObject(index)
                    Triple(
                        task.getString("id"),
                        task.getString("title").take(MAX_TEXT),
                        task.optText("note")?.take(MAX_TEXT),
                    )
                }
                val list = json.optJSONArray("frames") ?: JSONArray()
                val frames = (0 until list.length()).map { index ->
                    val frame = list.getJSONObject(index)
                    val rows = frame.optJSONArray("rows") ?: JSONArray()
                    HsFrame(
                        from = frame.optLong("from", 0L),
                        count = frame.optInt("count", 0).coerceAtLeast(0),
                        summary = frame.optString("summary", ""),
                        alert = frame.optText("alert"),
                        rows = (0 until rows.length()).mapNotNull { at ->
                            val row = rows.getJSONObject(at)
                            val task = tasks.getOrNull(row.optInt("t", -1))
                                ?: return@mapNotNull null
                            HsRow(
                                id = task.first,
                                title = task.second,
                                note = task.third,
                                due = row.optString("due", "").take(MAX_DUE),
                                overdue = row.optBoolean("overdue", false),
                                counted = row.optBoolean("counted", false),
                                say = row.optText("say")?.take(MAX_DUE),
                            )
                        }.take(MAX_ROWS),
                    )
                }.sortedBy { it.from }
                HsSnapshot(
                    text = json.optString("mode") == "text",
                    voice = json.optBoolean("voice", true),
                    until = if (json.isNull("until")) null else json.optLong("until"),
                    frames = frames,
                )
            }
        } catch (error: Exception) {
            null
        }
    }
}

/** Запись очереди отметок: применяет её приложение, не Android. */
data class HsOp(
    val seq: Long,
    val op: String,
    val task: String,
    val at: Long,
    val doneAt: Long? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("seq", seq)
        .put("op", op)
        .put("task", task)
        .put("at", at)
        .apply { if (doneAt != null) put("doneAt", doneAt) }

    /** Для канала: числа как Long — в Dart это int. */
    fun toMap(): Map<String, Any> = buildMap {
        put("seq", seq)
        put("op", op)
        put("task", task)
        put("at", at)
        if (doneAt != null) put("doneAt", doneAt)
    }

    companion object {
        fun fromJson(json: JSONObject): HsOp? = try {
            HsOp(
                seq = json.getLong("seq"),
                op = json.getString("op"),
                task = json.getString("task"),
                at = json.getLong("at"),
                doneAt = if (json.isNull("doneAt")) null else json.getLong("doneAt"),
            )
        } catch (error: Exception) {
            null
        }
    }
}

/**
 * Задача, отмеченная на виджете: пока приложение не подтвердило отметку,
 * строки в списке нет, а первые [HomeScreenStore.LINGER] мс она видна
 * зачёркнутой на прежнем месте [index] (повторное нажатие — «вернуть»).
 */
data class HsMark(
    val task: String,
    val at: Long,
    val seq: Long,
    val index: Int,
    val row: HsRow,
    /** Показ кончился, показанное напоминание задачи убрано. */
    val settled: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("at", at)
        .put("seq", seq)
        .put("index", index)
        .put("row", row.toJson())
        .put("settled", settled)

    companion object {
        fun fromJson(task: String, json: JSONObject): HsMark? = try {
            HsMark(
                task = task,
                at = json.getLong("at"),
                seq = json.getLong("seq"),
                index = json.optInt("index", 0),
                row = HsRow.fromJson(json.getJSONObject("row")) ?: return null,
                settled = json.optBoolean("settled", false),
            )
        } catch (error: Exception) {
            null
        }
    }
}

/** Строка на виджете: задача из снимка или только что отмеченная. */
data class HsItem(val row: HsRow, val done: Boolean)

/** Что показать на «Сегодня» сейчас. */
data class HsBoard(
    val state: State,
    /** Сколько дел (просроченные и на сегодня) с учётом отметок на виджете. */
    val count: Int,
    /** «3 дела» из приложения — для вида только с числами. */
    val summary: String?,
    /** «просрочена 1 задача» из приложения — для вида только с числами. */
    val alert: String?,
    val items: List<HsItem>,
    val voice: Boolean,
) {
    enum class State {
        /** Снимка нет: «Откройте Tridot — задачи появятся здесь». */
        PLACEHOLDER,

        /** Снимок устарел: «Откройте Tridot, чтобы обновить список». */
        EXPIRED,

        /** Текст задач показывать нельзя: только число дел. */
        COUNTS,

        /** Список задач. */
        LIST,
    }
}

/**
 * Хранилище виджетов (ADR-034): SharedPreferences `tridot_homescreen`,
 * исключены из резервной копии (res/xml/data_extraction_rules.xml,
 * backup_rules.xml) — это производные данные. Снимок лежит, только пока
 * стоит «Сегодня» или «Сегодня и ввод». Названия задач в журнал не
 * пишутся. Всё — на главном потоке процесса.
 *
 * - `snapshot` — снимок из приложения строкой, как пришёл.
 * - `voice` — показывать ли микрофон (хранится и без снимка).
 * - `ops` — очередь отметок, `seq` — последний номер, `delivered` — до
 *   какого номера очередь уже отдана приложению, `acked` — до какого
 *   подтверждена.
 * - `marks` — отметки на виджете по id задачи.
 * - `key` — случайный ключ установки в намерениях поля и микрофона
 *   (HomeScreenIntents.EXTRA_KEY): другое приложение его не знает.
 */
object HomeScreenStore {
    const val PREFS = "tridot_homescreen"

    /** Столько отмеченная строка видна зачёркнутой и её можно вернуть. */
    const val LINGER = 4_000L

    private const val SNAPSHOT = "snapshot"
    private const val VOICE = "voice"
    private const val OPS = "ops"
    private const val SEQ = "seq"
    private const val DELIVERED = "delivered"
    private const val ACKED = "acked"
    private const val MARKS = "marks"
    private const val KEY = "key"

    /** Очередь не растёт без предела, если приложение долго не открывают. */
    private const val MAX_OPS = 200

    const val OP_DONE = "done"
    const val OP_UNDO = "undo"

    /** Часы виджетов (подменяются в тестах). */
    @Volatile
    var clock: () -> Long = { System.currentTimeMillis() }

    fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ------------------------------------------------------------- снимок

    /**
     * Снимок из приложения. [keep] — стоит виджет с задачами: только тогда
     * снимок сохраняется, иначе стирается. Микрофон запоминается всегда.
     */
    fun saveSnapshot(context: Context, text: String, snapshot: HsSnapshot, keep: Boolean) {
        val prefs = prefs(context)
        val stored = if (keep) text else null
        // Виджетов с задачами нет — приложение шлёт снимки зря: не писать на диск.
        if (prefs.getString(SNAPSHOT, null) == stored &&
            prefs.contains(VOICE) && prefs.getBoolean(VOICE, true) == snapshot.voice
        ) {
            return
        }
        val edit = prefs.edit().putBoolean(VOICE, snapshot.voice)
        if (stored != null) edit.putString(SNAPSHOT, stored) else edit.remove(SNAPSHOT)
        edit.apply()
    }

    fun clearSnapshot(context: Context) {
        prefs(context).edit().remove(SNAPSHOT).apply()
    }

    fun hasSnapshot(context: Context): Boolean = prefs(context).contains(SNAPSHOT)

    fun snapshot(context: Context): HsSnapshot? =
        prefs(context).getString(SNAPSHOT, null)?.let(HsSnapshot::parse)

    /** Микрофон на виджете: пока приложение не сказало иного — есть. */
    fun voice(context: Context): Boolean = prefs(context).getBoolean(VOICE, true)

    // ----------------------------------------------------------- что видно

    fun board(context: Context, now: Long): HsBoard {
        val voice = voice(context)
        val snapshot = snapshot(context)
            ?: return HsBoard(HsBoard.State.PLACEHOLDER, 0, null, null, emptyList(), voice)
        val until = snapshot.until
        if (until != null && now >= until) {
            return HsBoard(HsBoard.State.EXPIRED, 0, null, null, emptyList(), snapshot.voice)
        }
        val frame = snapshot.frameAt(now)
            ?: return HsBoard(HsBoard.State.PLACEHOLDER, 0, null, null, emptyList(), snapshot.voice)
        if (!snapshot.text) {
            return HsBoard(
                HsBoard.State.COUNTS,
                frame.count,
                frame.summary,
                frame.alert,
                emptyList(),
                snapshot.voice,
            )
        }
        val marks = marks(context)
        val items = frame.rows.filter { it.id !in marks }
            .map { HsItem(it, done = false) }
            .toMutableList()
        marks.values
            .filter { now - it.at in 0 until LINGER }
            .sortedBy { it.index }
            .forEach { items.add(it.index.coerceIn(0, items.size), HsItem(it.row, done = true)) }
        val markedCounted = frame.rows.count { it.counted && it.id in marks }
        return HsBoard(
            HsBoard.State.LIST,
            (frame.count - markedCounted).coerceAtLeast(0),
            frame.summary,
            frame.alert,
            items,
            snapshot.voice,
        )
    }

    /**
     * Когда перерисовать без повода извне: начало следующего кадра, срок
     * годности снимка, конец показа отмеченной строки или ближайшая
     * полночь (дата в шапке) — что раньше.
     */
    fun nextBoundary(context: Context, now: Long): Long {
        var next = nextMidnight(now)
        snapshot(context)?.let { snapshot ->
            snapshot.nextFrom(now)?.let { next = minOf(next, it) }
            snapshot.until?.takeIf { it > now }?.let { next = minOf(next, it) }
        }
        marks(context).values
            .map { it.at + LINGER }
            .filter { it > now }
            .minOrNull()
            ?.let { next = minOf(next, it) }
        return next
    }

    fun nextMidnight(now: Long): Long = Calendar.getInstance().run {
        timeInMillis = now
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
        add(Calendar.DAY_OF_MONTH, 1)
        timeInMillis
    }

    // ------------------------------------------------------------ отметки

    /**
     * Нажали кружок у задачи [taskId]: запись `done` в очередь и отметка на
     * виджете. `null` — задачи на виджете уже нет или она уже отмечена.
     */
    fun addDone(context: Context, taskId: String, now: Long): HsOp? {
        val marks = marks(context).toMutableMap()
        if (taskId in marks) return null
        val board = board(context, now)
        if (board.state != HsBoard.State.LIST) return null
        val index = board.items.indexOfFirst { !it.done && it.row.id == taskId }
        if (index < 0) return null
        val prefs = prefs(context)
        val seq = prefs.getLong(SEQ, 0L) + 1
        val op = HsOp(seq, OP_DONE, taskId, now)
        marks[taskId] = HsMark(taskId, now, seq, index, board.items[index].row, settled = false)
        prefs.edit()
            .putLong(SEQ, seq)
            .putString(OPS, encodeOps((ops(context) + op).takeLast(MAX_OPS)))
            .putString(MARKS, encodeMarks(marks))
            .commit()
        return op
    }

    /**
     * Повторное нажатие на отмеченную строку. Отметку, которую приложение
     * ещё не забирало, можно просто убрать; забранную — только отменить
     * записью `undo` (приложение могло уже выполнить задачу). Возвращает
     * новую запись очереди или `null`, если записи не понадобилось.
     */
    fun undo(context: Context, taskId: String, now: Long): HsOp? {
        val marks = marks(context).toMutableMap()
        val mark = marks.remove(taskId) ?: return null
        val prefs = prefs(context)
        val queue = ops(context)
        val delivered = prefs.getLong(DELIVERED, 0L)
        val done = queue.firstOrNull { it.seq == mark.seq && it.op == OP_DONE }
        val edit = prefs.edit().putString(MARKS, encodeMarks(marks))
        var added: HsOp? = null
        if (done != null && done.seq > delivered) {
            edit.putString(OPS, encodeOps(queue - done))
        } else {
            val seq = prefs.getLong(SEQ, 0L) + 1
            added = HsOp(seq, OP_UNDO, taskId, now, doneAt = mark.at)
            edit.putLong(SEQ, seq).putString(OPS, encodeOps((queue + added).takeLast(MAX_OPS)))
        }
        edit.commit()
        return added
    }

    /** Задачу отметили на виджете, приложение ещё не ответило. */
    fun isMarkedDone(context: Context, taskId: String): Boolean = taskId in marks(context)

    /** Отметка задачи [taskId] или `null`. */
    fun mark(context: Context, taskId: String): HsMark? = marks(context)[taskId]

    /** Очередь для приложения; запоминает, до какого номера её отдали. */
    fun pending(context: Context): List<HsOp> {
        val queue = ops(context)
        val last = queue.maxOfOrNull { it.seq } ?: return queue
        val prefs = prefs(context)
        if (last > prefs.getLong(DELIVERED, 0L)) {
            prefs.edit().putLong(DELIVERED, last).commit()
        }
        return queue
    }

    /** Приложение применило записи до [upTo] включительно. */
    fun ack(context: Context, upTo: Long) {
        val prefs = prefs(context)
        val acked = maxOf(prefs.getLong(ACKED, 0L), upTo)
        prefs.edit()
            .putLong(ACKED, acked)
            .putString(OPS, encodeOps(ops(context).filter { it.seq > upTo }))
            .commit()
    }

    /**
     * Отметки, у которых кончился показ: у задачи убирается показанное
     * напоминание (один раз, [onSettled]); подтверждённые приложением
     * забываются — в новом снимке задачи уже нет (или правка в приложении
     * важнее, и строка вернулась). Расписание напоминаний не трогается:
     * пока отметка есть, ReminderReceiver их не показывает, а потом
     * приложение присылает расписание без задачи. Поэтому и запоздалое
     * «вернуть» ничего не теряет.
     */
    fun settle(context: Context, now: Long, onSettled: (String) -> Unit) {
        val marks = marks(context)
        if (marks.isEmpty()) return
        val acked = prefs(context).getLong(ACKED, 0L)
        val next = mutableMapOf<String, HsMark>()
        var changed = false
        for ((task, mark) in marks) {
            if (now - mark.at < LINGER && now >= mark.at) {
                next[task] = mark
                continue
            }
            var kept = mark
            if (!mark.settled) {
                onSettled(task)
                kept = mark.copy(settled = true)
                changed = true
            }
            if (mark.seq <= acked) {
                changed = true
            } else {
                next[task] = kept
            }
        }
        if (changed) prefs(context).edit().putString(MARKS, encodeMarks(next)).commit()
    }

    /**
     * Ключ установки для намерений поля и микрофона (создаётся при первом
     * обращении). Совпал — нажали наш виджет, а не другое приложение.
     */
    fun launchKey(context: Context): String {
        val prefs = prefs(context)
        prefs.getString(KEY, null)?.takeIf { it.isNotEmpty() }?.let { return it }
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val key = bytes.joinToString("") { "%02x".format(it) }
        prefs.edit().putString(KEY, key).commit()
        return key
    }

    fun ops(context: Context): List<HsOp> {
        val text = prefs(context).getString(OPS, null) ?: return emptyList()
        return try {
            val array = JSONArray(text)
            (0 until array.length()).mapNotNull { HsOp.fromJson(array.getJSONObject(it)) }
        } catch (error: Exception) {
            emptyList()
        }
    }

    fun marks(context: Context): Map<String, HsMark> {
        val text = prefs(context).getString(MARKS, null) ?: return emptyMap()
        return try {
            val json = JSONObject(text)
            json.keys().asSequence().mapNotNull { task ->
                json.optJSONObject(task)?.let { HsMark.fromJson(task, it) }
            }.associateBy { it.task }
        } catch (error: Exception) {
            emptyMap()
        }
    }

    private fun encodeOps(ops: List<HsOp>): String =
        JSONArray().apply { ops.forEach { put(it.toJson()) } }.toString()

    private fun encodeMarks(marks: Map<String, HsMark>): String =
        JSONObject().apply { marks.forEach { (task, mark) -> put(task, mark.toJson()) } }.toString()
}

private const val MAX_TEXT = 200
private const val MAX_DUE = 60
private const val MAX_ROWS = 12

/** Строка или `null` (нет поля или JSON null). */
private fun JSONObject.optText(name: String): String? =
    if (isNull(name)) null else optString(name, "").ifEmpty { null }
