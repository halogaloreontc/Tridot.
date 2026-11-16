package com.example.local_assistant.homescreen

import android.app.Application
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.os.Looper
import android.text.Spanned
import android.text.style.StrikethroughSpan
import android.util.SizeF
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.RemoteViews
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import com.example.local_assistant.R
import java.io.File
import kotlin.math.roundToInt
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Виджеты, нарисованные так, как их разворачивает лаунчер: контекст
 * пакета с CONTEXT_RESTRICTED (шрифт из res/font он бы не загрузил),
 * родитель — AppWidgetHostView, вид по размеру выбирает сам RemoteViews.
 * Проверяется строение (ни одна строка не обрезана, нужные строки на
 * месте); с `-Ptridot.shots=<папка>` снимки сохраняются в PNG — светлая и
 * тёмная тема, состояния и крупный шрифт.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = Application::class, qualifiers = "w412dp-h915dp-420dpi")
class HomeScreenShotsTest {
    private val out: File? = System.getProperty("tridot.shots")?.let { File(it).apply { mkdirs() } }
    private val now = Fixtures.now
    private val sheet = mutableListOf<Pair<String, Bitmap>>()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @After
    fun tearDown() {
        RuntimeEnvironment.setFontScale(1f)
        HomeScreenStore.clock = { System.currentTimeMillis() }
    }

    private fun reset(text: String?) {
        HomeScreenStore.prefs(context).edit().clear().commit()
        if (text != null) {
            HomeScreenStore.saveSnapshot(context, text, HsSnapshot.parse(text)!!, keep = true)
        }
    }

    private val night: Boolean
        get() = context.resources.configuration.uiMode and 0x30 == 0x20

    /** Рисует виджет [kind] размером [w]×[h] dp и возвращает его вид. */
    private fun render(kind: HsKind, w: Int, h: Int, name: String): View {
        val ctx = context
        val board = HomeScreenStore.board(ctx, now)
        val options = Bundle().apply {
            putParcelableArrayList(
                AppWidgetManager.OPTION_APPWIDGET_SIZES,
                arrayListOf(SizeF(w.toFloat(), h.toFloat()), SizeF(w * 0.8f, h * 0.6f)),
            )
        }
        val views = HomeScreenRenderer.build(ctx, kind, board, options, now)
        return show(views, w, h, name)
    }

    /** Разворачивает [views] как лаунчер и сохраняет снимок. */
    private fun show(views: RemoteViews, w: Int, h: Int, name: String): View {
        val ctx = context
        val restricted = ctx.createPackageContext(ctx.packageName, Context.CONTEXT_RESTRICTED)
        val host = AppWidgetHostView(restricted)
        val apply = RemoteViews::class.java.methods.first {
            it.name == "apply" && it.parameterCount == 4 && it.parameterTypes[3] == SizeF::class.java
        }
        host.addView(apply.invoke(views, restricted, host, null, SizeF(w.toFloat(), h.toFloat())) as View)
        val density = ctx.resources.displayMetrics.density
        val pad = (12 * density).roundToInt()
        val width = (w * density).roundToInt() + 2 * pad
        val height = (h * density).roundToInt() + 2 * pad
        val frame = FrameLayout(ctx).apply {
            setPadding(pad, pad, pad, pad)
            addView(host)
        }
        repeat(3) {
            frame.measure(
                View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY),
            )
            frame.layout(0, 0, width, height)
            shadowOf(Looper.getMainLooper()).idle()
        }
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        // Условные обои: виден край карточки.
        canvas.drawColor(if (night) Color.rgb(0x2A, 0x2F, 0x38) else Color.rgb(0xC6, 0xD0, 0xDA))
        frame.draw(canvas)
        val label = "${if (night) "dark" else "light"}-$name"
        out?.let { dir -> File(dir, "$label.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
        sheet.add(label to bitmap)
        assertNoCut(host, label)
        return host
    }

    /** Ни одна строка не выходит за низ списка: только целые строки. */
    private fun assertNoCut(host: View, label: String) {
        val rows = host.findViewById<ViewGroup>(R.id.hw_rows) ?: return
        for (index in 0 until rows.childCount) {
            val child = rows.getChildAt(index)
            assertTrue(
                "$label: строка $index обрезана (${child.bottom} > ${rows.height})",
                child.bottom <= rows.height,
            )
        }
    }

    private fun titles(host: View): List<TextView> {
        val found = mutableListOf<TextView>()
        fun walk(view: View) {
            if (view is TextView && view.id == R.id.hw_title) found.add(view)
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(host)
        return found
    }

    private fun text(host: View, id: Int): String? =
        host.findViewById<TextView>(id)?.takeIf { it.visibility == View.VISIBLE }?.text?.toString()

    private fun visible(host: View, id: Int): Boolean =
        host.findViewById<View>(id)?.visibility == View.VISIBLE

    private fun rowCount(host: View): Int = titles(host).size

    private val density: Float get() = context.resources.displayMetrics.density

    /** Все виды с [id] внутри [host]. */
    private fun all(host: View, id: Int): List<View> {
        val found = mutableListOf<View>()
        fun walk(view: View) {
            if (view.id == id) found.add(view)
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(host)
        return found
    }

    /** Все видимые тексты внутри [view]. */
    private fun texts(view: View): List<TextView> {
        val found = mutableListOf<TextView>()
        fun walk(child: View) {
            if (child.visibility != View.VISIBLE) return
            if (child is TextView) found.add(child)
            if (child is ViewGroup) for (i in 0 until child.childCount) walk(child.getChildAt(i))
        }
        walk(view)
        return found
    }

    /** Прямоугольник [view] в dp относительно [root]. */
    private fun box(view: View, root: View): RectF {
        var x = 0f
        var y = 0f
        var at: View? = view
        while (at != null && at !== root) {
            x += at.left
            y += at.top
            at = at.parent as? View
        }
        return RectF(x / density, y / density, (x + view.width) / density, (y + view.height) / density)
    }

    private fun ellipsized(text: TextView): Boolean =
        text.layout?.let { it.lineCount > 0 && it.getEllipsisCount(0) > 0 } ?: false

    /** Кружок строки: картинка внутри зоны hw_check. */
    private fun ring(check: View): View {
        fun find(view: View): View? {
            if (view is android.widget.ImageView) return view
            if (view is ViewGroup) for (i in 0 until view.childCount) find(view.getChildAt(i))?.let { return it }
            return null
        }
        return find(check)!!
    }

    private fun states() {
        reset(Fixtures.snapshot())
        render(HsKind.TODAY, 368, 220, "today-4x2").also { host ->
            assertEquals("5 дел", text(host, R.id.hw_count))
            assertEquals("· пн, 16 ноября", text(host, R.id.hw_date))
            assertTrue(rowCount(host) >= 3)
            assertNotNull(text(host, R.id.hw_more))
            // Просроченный срок — цветом ошибки, не приглушённым.
            assertTrue(visible(host, R.id.hw_due_over))
        }
        render(HsKind.TODAY, 368, 340, "today-4x3").also { host ->
            // Все дела на сегодня и ближайшая задача; записи не вытесняют
            // строк (с записями — limits()).
            assertTrue(rowCount(host) >= 6)
            assertNull(text(host, R.id.hw_more))
        }
        render(HsKind.TODAY, 180, 220, "today-2x2-narrow").also { host ->
            assertEquals("", text(host, R.id.hw_date))
            assertEquals("5 дел", text(host, R.id.hw_count))
            // Число дел прижато к правому краю и без даты.
            val count = host.findViewById<View>(R.id.hw_count)
            val header = host.findViewById<View>(R.id.hw_header)
            assertTrue(header.width - count.right <= (17 * context.resources.displayMetrics.density).toInt())
        }
        render(HsKind.COMBO, 368, 340, "combo-4x3").also { host ->
            assertTrue(visible(host, R.id.hw_field))
            assertTrue(visible(host, R.id.hw_field_mic))
            assertTrue(rowCount(host) >= 3)
        }
        render(HsKind.COMBO, 368, 220, "combo-4x2").also { host ->
            assertTrue(visible(host, R.id.hw_field))
            assertTrue(rowCount(host) >= 1)
        }
        render(HsKind.QUICK, 368, 106, "quick-4x1").also { host ->
            assertTrue(visible(host, R.id.hw_mic_zone))
            assertEquals("Что сделать?", text(host, R.id.hw_hint))
        }

        // Только что отмеченная: на месте, зачёркнута, число дел меньше.
        reset(Fixtures.snapshot())
        HomeScreenStore.addDone(context, "task_2", now - 1_000L)
        render(HsKind.TODAY, 368, 220, "today-just-done").also { host ->
            assertEquals("4 дела", text(host, R.id.hw_count))
            val done = titles(host).first { it.text.toString() == "Сдать реестр по складу" }
            val spans = (done.text as Spanned).getSpans(0, done.text.length, StrikethroughSpan::class.java)
            assertEquals(1, spans.size)
        }

        // Длинное название просрочено: срок не сокращается.
        val long = listOf(
            Fixtures.Task(
                "task_long",
                "Согласовать с подрядчиком смету на ремонт кровли и подъезда",
                "14 ноября",
                overdue = true,
                note = "Позвонить Ивану после обеда",
            ),
        ) + Fixtures.week.drop(1).take(2)
        reset(Fixtures.snapshot(tasks = long, count = 3))
        render(HsKind.TODAY, 368, 220, "today-overdue-long").also { host ->
            assertEquals("14 ноября", text(host, R.id.hw_due_over))
        }

        reset(Fixtures.snapshot(tasks = emptyList(), count = 0, alert = null))
        render(HsKind.TODAY, 368, 220, "today-empty").also { host ->
            assertEquals("На сегодня дел нет", text(host, R.id.hw_msg))
            assertEquals("Нажмите, чтобы добавить", text(host, R.id.hw_msg_sub))
            assertFalse(visible(host, R.id.hw_count))
        }
        render(HsKind.COMBO, 368, 220, "combo-empty").also { host ->
            assertEquals("На сегодня дел нет", text(host, R.id.hw_msg))
            assertNull(text(host, R.id.hw_msg_sub))
        }

        reset(Fixtures.snapshot(tasks = Fixtures.week.filter { !it.counted }, count = 0, alert = null))
        render(HsKind.TODAY, 368, 220, "today-only-upcoming").also { host ->
            assertEquals(2, rowCount(host))
            assertTrue(visible(host, R.id.hw_empty_row))
            assertFalse(visible(host, R.id.hw_count))
        }

        reset(Fixtures.snapshot(text = false, count = 5, summary = "5 дел"))
        render(HsKind.TODAY, 368, 220, "today-counts-only").also { host ->
            assertEquals(0, rowCount(host))
            assertEquals("5 дел", text(host, R.id.hw_msg_strong))
            assertEquals("просрочена 1 задача", text(host, R.id.hw_msg_alert))
        }

        reset(Fixtures.snapshot(until = now - 1))
        render(HsKind.TODAY, 368, 220, "today-expired").also { host ->
            assertEquals("Откройте Tridot, чтобы обновить список", text(host, R.id.hw_msg))
        }

        reset(null)
        render(HsKind.TODAY, 368, 220, "today-placeholder").also { host ->
            assertEquals("Откройте Tridot — задачи появятся здесь", text(host, R.id.hw_msg))
        }

        reset(Fixtures.snapshot(voice = false))
        render(HsKind.QUICK, 368, 106, "quick-no-voice").also { host ->
            assertFalse(visible(host, R.id.hw_mic_zone))
        }
        render(HsKind.COMBO, 368, 220, "combo-no-voice").also { host ->
            assertFalse(visible(host, R.id.hw_field_mic))
        }
    }

    /** Образцы в списке виджетов лаунчера и пустая карточка — настоящие RemoteViews. */
    private fun previews() {
        listOf(
            Triple(R.layout.hw_today_preview, 368 to 220, "preview-today"),
            Triple(R.layout.hw_combo_preview, 368 to 340, "preview-combo"),
            Triple(R.layout.hw_quick, 368 to 106, "preview-quick"),
            Triple(R.layout.hw_loading, 368 to 220, "loading"),
        ).forEach { (layout, size, name) ->
            val views = RemoteViews(context.packageName, layout)
            show(views, size.first, size.second, name)
        }
    }

    private fun scaled(scale: Float) {
        RuntimeEnvironment.setFontScale(scale)
        val tag = "scale-${(scale * 100).roundToInt()}"
        reset(Fixtures.snapshot())
        render(HsKind.TODAY, 368, 220, "today-4x2-$tag")
        render(HsKind.TODAY, 368, 340, "today-4x3-$tag")
        render(HsKind.COMBO, 368, 340, "combo-4x3-$tag")
        render(HsKind.QUICK, 368, 106, "quick-4x1-$tag")
        RuntimeEnvironment.setFontScale(1f)
    }

    private fun saveSheet(name: String) {
        val dir = out ?: return
        val labelHeight = 44
        val gap = 16
        val width = sheet.maxOf { it.second.width }
        val height = sheet.sumOf { it.second.height + labelHeight + gap }
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(if (night) Color.rgb(0x16, 0x18, 0x1C) else Color.WHITE)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 28f
            color = if (night) Color.LTGRAY else Color.DKGRAY
        }
        var y = 0
        sheet.forEach { (label, shot) ->
            canvas.drawText(label, 12f, y + 32f, paint)
            canvas.drawBitmap(shot, 0f, (y + labelHeight).toFloat(), null)
            y += shot.height + labelHeight + gap
        }
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        sheet.clear()
    }

    /**
     * Пределы из ревью: самый низкий размер, запись во всю ширину, цели
     * нажатия не меньше 48 dp, крупный шрифт и узкий «Быстрый ввод».
     */
    private fun limits(scale: Float) {
        RuntimeEnvironment.setFontScale(scale)
        val tag = "s${(scale * 100).roundToInt()}"
        reset(Fixtures.snapshot())

        // Сжатые до предела (minResizeHeight): одна задача без «ещё N», число
        // дел — только в шапке. При шрифте 200 % строка в две строки текста
        // не помещается — тогда только шапка (и поле), без «ещё N».
        for ((kind, h) in listOf(HsKind.TODAY to 110, HsKind.COMBO to 175)) {
            render(kind, 368, h, "${kind.key}-min-$tag").also { host ->
                if (scale <= 1.3f) assertEquals("$tag ${kind.key}", 1, rowCount(host))
                assertNull(text(host, R.id.hw_more))
                val rows = host.findViewById<View>(R.id.hw_rows)
                assertTrue(texts(rows).none { it.text.toString() == "5 дел" })
                assertEquals("5 дел", text(host, R.id.hw_count))
            }
        }

        // Запись — во всю ширину под сроком, кружок — напротив названия.
        if (scale < 2f) {
            reset(Fixtures.snapshot(tasks = Fixtures.week.filter { it.counted }))
            render(HsKind.TODAY, 368, 340, "today-notes-$tag").also { host ->
                val notes = all(host, R.id.hw_note)
                assertEquals(2, notes.size)
                notes.forEach { note ->
                    val row = generateSequence(note) { it.parent as? View }.first { it.id == R.id.hw_body }
                    val due = box(all(row, R.id.hw_due).first { it.visibility == View.VISIBLE }, host)
                    val title = box(all(row, R.id.hw_title).single(), host)
                    val noteBox = box(note, host)
                    assertTrue("$tag: запись под сроком", noteBox.right >= due.right - 1f)
                    assertEquals(title.left, noteBox.left, 0.5f)
                    assertTrue(noteBox.top >= title.bottom)
                }
                assertRings(host, tag)
            }
            reset(Fixtures.snapshot())
        }

        // Цели нажатия: кружок, поле, микрофон — не меньше 48 dp, шапка — 40.
        render(HsKind.COMBO, 368, 340, "combo-targets-$tag").also { host ->
            assertRings(host, tag)
            assertTrue(box(host.findViewById(R.id.hw_header), host).height() >= 39.9f)
            assertTrue(box(host.findViewById(R.id.hw_field_body), host).height() >= 47.9f)
            val mic = box(host.findViewById(R.id.hw_field_mic), host)
            assertTrue(mic.width() >= 47.9f && mic.height() >= 47.9f)
            // «ещё N» — не цель нажатия.
            host.findViewById<View>(R.id.hw_more)?.let { assertFalse(it.isClickable) }
            // Дата в шапке — целиком или никак.
            val date = host.findViewById<TextView>(R.id.hw_date)
            assertFalse("$tag: дата обрезана", ellipsized(date))
        }

        // «Быстрый ввод» самой малой ширины (250 dp): подпись целиком, при
        // шрифте 200 % — от трёх ячеек (280 dp; на 250 она мельчает до 13 sp
        // и всё же теряет букву).
        val quickWidth = if (scale < 2f) 250 else 280
        render(HsKind.QUICK, quickWidth, 72, "quick-min-$tag").also { host ->
            assertFalse("$tag: «Что сделать?» обрезано", ellipsized(host.findViewById(R.id.hw_hint)))
        }
        render(HsKind.COMBO, 250, 220, "combo-narrow-$tag").also { host ->
            if (scale < 2f) {
                assertFalse("$tag: поле обрезано", ellipsized(host.findViewById(R.id.hw_field_hint)))
            }
        }
        RuntimeEnvironment.setFontScale(1f)
    }

    /** Зона кружка не меньше 48 dp, кружок — посередине названия своей строки. */
    private fun assertRings(host: View, tag: String) {
        val checks = all(host, R.id.hw_check)
        assertTrue(checks.isNotEmpty())
        checks.forEach { check ->
            val zone = box(check, host)
            assertTrue("$tag: зона кружка ${zone.width()}×${zone.height()}", zone.width() >= 47.9f && zone.height() >= 47.9f)
            val body = check.parent as View
            val title = box(all(body, R.id.hw_title).single(), host)
            assertEquals("$tag: кружок у названия", title.centerY(), box(ring(check), host).centerY(), 1.5f)
        }
    }

    @Test
    fun limits() {
        RuntimeEnvironment.setQualifiers("+night")
        limits(1f)
        limits(1.3f)
        limits(2f)
        // Очень крупный шрифт: срок под названием, а не рядом с огрызком.
        RuntimeEnvironment.setFontScale(2f)
        reset(Fixtures.snapshot())
        render(HsKind.TODAY, 368, 340, "today-narrow-s200").also { host ->
            val title = host.findViewById<View>(R.id.hw_title)
            val body = generateSequence(title) { it.parent as? View }.first { it.id == R.id.hw_body }
            val due = all(body, R.id.hw_due).plus(all(body, R.id.hw_due_over)).first { it.visibility == View.VISIBLE }
            assertTrue(box(due, host).top >= box(title, host).bottom)
            assertEquals("", text(host, R.id.hw_date))
            assertRings(host, "s200")
        }
        RuntimeEnvironment.setFontScale(1f)
        saveSheet("sheet-limits")
    }

    @Test
    fun light() {
        RuntimeEnvironment.setQualifiers("+notnight")
        states()
        previews()
        saveSheet("sheet-light")
    }

    @Test
    fun dark() {
        RuntimeEnvironment.setQualifiers("+night")
        states()
        previews()
        saveSheet("sheet-dark")
    }

    @Test
    fun largeText() {
        RuntimeEnvironment.setQualifiers("+night")
        scaled(1.3f)
        scaled(2f)
        saveSheet("sheet-dark-large-text")
        RuntimeEnvironment.setQualifiers("+notnight")
        scaled(1.3f)
        saveSheet("sheet-light-large-text")
    }
}
