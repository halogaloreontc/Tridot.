package com.example.local_assistant.homescreen

import android.appwidget.AppWidgetManager
import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import android.text.style.StrikethroughSpan
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.example.local_assistant.R
import java.util.Calendar

/**
 * Вид виджетов (ADR-034): RemoteViews для «Сегодня», «Быстрого ввода» и
 * обоих вместе. Цвета, шрифт и скругления — в ресурсах (res/values*,
 * res/layout/hw_*.xml): лаунчер сам перечитывает их при смене темы
 * телефона. Строки списка — отдельными видами со своими PendingIntent,
 * только целиком (HomeScreenPlanner).
 */
object HomeScreenRenderer {
    /**
     * Уже (в dp при обычном шрифте) — узкий вид: срок под названием, без
     * записей. Крупный шрифт сужает виджет во столько же раз.
     */
    const val NARROW_DP = 250f

    /**
     * Срок шире этой доли ширины виджета — тоже узкий вид: иначе от
     * названия остаётся пара слов.
     */
    const val DUE_SHARE = 0.35f

    /** Запас на округление пикселей: последняя строка не обрезается. */
    private const val SAFETY_DP = 2f

    /** Отступ под списком «Сегодня» (paddingBottom в hw_today.xml). */
    private const val BOTTOM_DP = 6f

    /** Поле в «Сегодня и ввод»: отступы сверху и снизу (hw_field.xml, 4 + 8). */
    private const val FIELD_GAP_DP = 12f

    /** Шапка: отступы по краям (16 + 16) и между словами (hw_header.xml). */
    private const val HEADER_SIDES_DP = 32f
    private const val HEADER_DATE_GAP_DP = 4f
    private const val HEADER_COUNT_GAP_DP = 12f

    /** Высоты и ширины по шрифту телефона — те же формулы, что в макетах. */
    class Metrics(context: Context) {
        private val metrics = context.resources.displayMetrics
        private val head = context.getString(R.string.hw_today)

        private fun paint(sp: Float, medium: Boolean = false, digits: Boolean = false): TextPaint {
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)
            paint.typeface = Typeface.create(
                if (medium) "sans-serif-medium" else "sans-serif",
                Typeface.NORMAL,
            )
            paint.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, metrics)
            if (digits) paint.fontFeatureSettings = "tnum"
            return paint
        }

        private fun line(sp: Float, medium: Boolean = false): Float {
            val font = paint(sp, medium).fontMetricsInt
            return (font.descent - font.ascent) / metrics.density
        }

        private val title = line(15f)
        private val meta = line(13f)
        private val headPaint = paint(13f, medium = true)
        private val metaPaint = paint(13f)
        private val duePaint = paint(13f, digits = true)

        /**
         * Во сколько раз крупнее обычного названия задач (15 sp): масштаб
         * шрифта телефона, на Android 14 — нелинейный.
         */
        val scale: Float =
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 15f, metrics) / (15f * metrics.density)

        /** hw_header.xml: minHeight 40, отступы 12 + 8. */
        val header = maxOf(40f, 20f + maxOf(line(13f, medium = true), meta))

        /** hw_field.xml: minHeight 48, отступы 8 + 8, подпись 15sp. */
        val field = maxOf(48f, 16f + title)

        val heights = HsHeights(
            // hw_row.xml, hw_row_done.xml: minHeight 48, отступы 10 + 10.
            row = maxOf(48f, 20f + title),
            // hw_row_note.xml, hw_row_narrow.xml: 10 + название + 2 + 13sp + 10.
            rowNote = maxOf(48f, 22f + title + meta),
            // hw_empty_row.xml: minHeight 40, отступы 8 + 8.
            empty = maxOf(40f, 16f + title),
            // hw_more.xml: minHeight 28, отступы 6 + 6.
            more = maxOf(28f, 12f + meta),
        )

        /** Высота под строки списка у виджета высотой [height] dp. */
        fun room(kind: HsKind, height: Float): Float {
            val below = if (kind == HsKind.COMBO) FIELD_GAP_DP + field else BOTTOM_DP
            return height - header - below - SAFETY_DP
        }

        private fun width(paint: TextPaint, text: String): Float =
            paint.measureText(text) / metrics.density

        /** Узкий вид при ширине [width] dp: срок под названием, без записей. */
        fun narrow(width: Float, items: List<HsItem>): Boolean {
            if (width / scale < NARROW_DP) return true
            val due = items.maxOfOrNull { width(duePaint, it.row.due) } ?: 0f
            return due > DUE_SHARE * width
        }

        /** Дата в шапке помещается целиком рядом с «Сегодня» и числом дел. */
        fun dateFits(width: Float, date: String, count: String?): Boolean {
            var need = HEADER_SIDES_DP + width(headPaint, head) + HEADER_DATE_GAP_DP + width(metaPaint, date)
            if (count != null) need += HEADER_COUNT_GAP_DP + width(metaPaint, count)
            return need + SAFETY_DP <= width
        }
    }

    fun build(
        context: Context,
        kind: HsKind,
        board: HsBoard,
        options: Bundle?,
        now: Long,
        metrics: Metrics = Metrics(context),
    ): RemoteViews {
        if (kind == HsKind.QUICK) return quick(context, board.voice)
        val sizes = sizes(kind, options)
        if (sizes.size == 1) return tasks(context, kind, board, sizes[0], now, metrics)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Лаунчер сам выберет вид под настоящий размер.
            return RemoteViews(sizes.associateWith { tasks(context, kind, board, it, now, metrics) })
        }
        // До Android 12: книжная — узко и высоко, альбомная — широко и низко.
        return RemoteViews(
            tasks(context, kind, board, sizes[1], now, metrics),
            tasks(context, kind, board, sizes[0], now, metrics),
        )
    }

    /** Размеры виджета в dp из параметров лаунчера. */
    fun sizes(kind: HsKind, options: Bundle?): List<SizeF> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && options != null) {
            @Suppress("DEPRECATION")
            val list = options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                ?.filter { it.width > 0 && it.height > 0 }
                ?.distinct()
                ?.take(MAX_SIZES)
            if (!list.isNullOrEmpty()) return list
        }
        val minWidth = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0
        val maxWidth = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH) ?: 0
        val minHeight = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
        val maxHeight = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT) ?: 0
        if (minWidth <= 0 || minHeight <= 0) return listOf(kind.fallback)
        return listOf(
            SizeF(minWidth.toFloat(), maxOf(maxHeight, minHeight).toFloat()),
            SizeF(maxOf(maxWidth, minWidth).toFloat(), minHeight.toFloat()),
        ).distinct()
    }

    // ------------------------------------------------------ «Быстрый ввод»

    fun quick(context: Context, voice: Boolean): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.hw_quick)
        views.setOnClickPendingIntent(R.id.hw_pill_body, HomeScreenIntents.compose(context))
        views.setOnClickPendingIntent(R.id.hw_mic_zone, HomeScreenIntents.voice(context))
        views.setViewVisibility(R.id.hw_mic_zone, if (voice) View.VISIBLE else View.GONE)
        return views
    }

    // ------------------------------------------------ «Сегодня» и вместе

    fun tasks(
        context: Context,
        kind: HsKind,
        board: HsBoard,
        size: SizeF,
        now: Long,
        metrics: Metrics = Metrics(context),
    ): RemoteViews {
        val combo = kind == HsKind.COMBO
        val views = RemoteViews(context.packageName, if (combo) R.layout.hw_combo else R.layout.hw_today)
        val narrow = metrics.narrow(size.width, board.items)
        header(context, views, board, size.width, now, metrics)
        views.removeAllViews(R.id.hw_rows)
        when (board.state) {
            HsBoard.State.PLACEHOLDER -> views.addView(
                R.id.hw_rows,
                message(context, text = context.getString(R.string.hw_placeholder)),
            )
            HsBoard.State.EXPIRED -> views.addView(
                R.id.hw_rows,
                message(context, text = context.getString(R.string.hw_expired)),
            )
            HsBoard.State.COUNTS -> views.addView(
                R.id.hw_rows,
                if (board.count == 0) {
                    message(context, text = context.getString(R.string.hw_empty))
                } else {
                    message(
                        context,
                        strong = board.summary?.ifEmpty { null } ?: deeds(context, board.count),
                        alert = board.alert,
                    )
                },
            )
            HsBoard.State.LIST -> if (board.items.isEmpty()) {
                views.addView(
                    R.id.hw_rows,
                    message(
                        context,
                        text = context.getString(R.string.hw_empty),
                        // В «Сегодня и ввод» поле и так под рукой.
                        sub = if (combo) null else context.getString(R.string.hw_empty_hint),
                        click = HomeScreenIntents.compose(context),
                    ),
                )
            } else {
                list(context, views, kind, board, size, narrow, metrics)
            }
        }
        if (combo) {
            views.setOnClickPendingIntent(R.id.hw_field_body, HomeScreenIntents.compose(context))
            views.setOnClickPendingIntent(R.id.hw_field_mic, HomeScreenIntents.voice(context))
            views.setViewVisibility(R.id.hw_field_mic, if (board.voice) View.VISIBLE else View.GONE)
        }
        return views
    }

    private fun header(
        context: Context,
        views: RemoteViews,
        board: HsBoard,
        width: Float,
        now: Long,
        metrics: Metrics,
    ) {
        views.setOnClickPendingIntent(R.id.hw_header, HomeScreenIntents.app(context))
        val count = if (board.state == HsBoard.State.LIST && board.count > 0) {
            deeds(context, board.count)
        } else {
            null
        }
        views.setViewVisibility(R.id.hw_count, if (count != null) View.VISIBLE else View.GONE)
        if (count != null) views.setTextViewText(R.id.hw_count, count)
        // Дата — только целиком, не «пн, 16 ноя…»; место остаётся, число
        // дел — справа.
        val date = dateLabel(context, now)
        views.setTextViewText(R.id.hw_date, if (metrics.dateFits(width, date, count)) date else "")
    }

    private fun list(
        context: Context,
        views: RemoteViews,
        kind: HsKind,
        board: HsBoard,
        size: SizeF,
        narrow: Boolean,
        metrics: Metrics,
    ) {
        val plan = HomeScreenPlanner.plan(
            board.items,
            board.count,
            metrics.room(kind, size.height),
            metrics.heights,
            narrow,
        )
        plan.lines.forEachIndexed { index, line ->
            val divider = index > 0
            views.addView(
                R.id.hw_rows,
                when (line) {
                    HsPlan.Line.Empty -> empty(context, divider)
                    is HsPlan.Line.Task -> row(context, board.items[line.item], line.note, narrow, divider)
                },
            )
        }
        // Только под строками: без них число дел и так в шапке. Не
        // нажимается — Tridot открывает шапка над списком.
        if (plan.more > 0 && plan.lines.isNotEmpty()) {
            val more = RemoteViews(context.packageName, R.layout.hw_more)
            more.setTextViewText(R.id.hw_more, context.getString(R.string.hw_more, plan.more))
            views.addView(R.id.hw_rows, more)
        }
    }

    private fun row(
        context: Context,
        item: HsItem,
        note: Boolean,
        narrow: Boolean,
        divider: Boolean,
    ): RemoteViews {
        val row = item.row
        val layout = when {
            item.done -> R.layout.hw_row_done
            narrow -> R.layout.hw_row_narrow
            note -> R.layout.hw_row_note
            else -> R.layout.hw_row
        }
        val views = RemoteViews(context.packageName, layout)
        views.setViewVisibility(R.id.hw_divider, if (divider) View.VISIBLE else View.GONE)
        if (item.done) {
            views.setTextViewText(R.id.hw_title, struck(row.title))
        } else {
            views.setTextViewText(R.id.hw_title, row.title)
        }
        if (note && !narrow && !item.done) views.setTextViewText(R.id.hw_note, row.note ?: "")
        val overdue = row.overdue && !item.done
        val showDue = !(item.done && narrow) && row.due.isNotEmpty()
        views.setTextViewText(R.id.hw_due, row.due)
        views.setTextViewText(R.id.hw_due_over, row.due)
        views.setViewVisibility(R.id.hw_due, if (showDue && !overdue) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.hw_due_over, if (showDue && overdue) View.VISIBLE else View.GONE)
        views.setContentDescription(R.id.hw_body, describe(context, item))
        views.setOnClickPendingIntent(R.id.hw_body, HomeScreenIntents.openTask(context, row.id))
        if (item.done) {
            views.setContentDescription(R.id.hw_check, context.getString(R.string.hw_mark_undo, row.title))
            views.setOnClickPendingIntent(R.id.hw_check, HomeScreenIntents.undo(context, row.id))
        } else {
            views.setContentDescription(R.id.hw_check, context.getString(R.string.hw_mark_done, row.title))
            views.setOnClickPendingIntent(R.id.hw_check, HomeScreenIntents.done(context, row.id))
        }
        return views
    }

    /** Для чтения с экрана: «Купить хлеб, вчера, просрочено, запись…». */
    private fun describe(context: Context, item: HsItem): String {
        val row = item.row
        val parts = mutableListOf(row.title)
        if (item.done) {
            parts.add(context.getString(R.string.hw_done_say))
        } else {
            (row.say ?: row.due).takeIf { it.isNotEmpty() }?.let(parts::add)
            row.note?.let(parts::add)
        }
        return parts.joinToString(", ")
    }

    private fun empty(context: Context, divider: Boolean): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.hw_empty_row)
        views.setViewVisibility(R.id.hw_divider, if (divider) View.VISIBLE else View.GONE)
        return views
    }

    private fun message(
        context: Context,
        text: String? = null,
        strong: String? = null,
        sub: String? = null,
        alert: String? = null,
        click: android.app.PendingIntent = HomeScreenIntents.app(context),
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.hw_message)
        fun show(id: Int, value: String?) {
            if (value.isNullOrEmpty()) {
                views.setViewVisibility(id, View.GONE)
            } else {
                views.setViewVisibility(id, View.VISIBLE)
                views.setTextViewText(id, value)
            }
        }
        show(R.id.hw_msg, text)
        show(R.id.hw_msg_strong, strong)
        show(R.id.hw_msg_sub, sub)
        show(R.id.hw_msg_alert, alert)
        views.setOnClickPendingIntent(R.id.hw_message, click)
        return views
    }

    private fun struck(text: String): CharSequence = SpannableString(text).apply {
        setSpan(StrikethroughSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    /** «· пн, 16 ноября» — как todayDateLabel() в приложении. */
    fun dateLabel(context: Context, now: Long): String {
        val calendar = Calendar.getInstance().apply { timeInMillis = now }
        val weekdays = context.resources.getStringArray(R.array.hw_weekdays)
        val months = context.resources.getStringArray(R.array.hw_months)
        // Calendar: воскресенье — 1, понедельник — 2; у нас с понедельника.
        val weekday = weekdays[(calendar.get(Calendar.DAY_OF_WEEK) + 5) % 7]
        return context.getString(
            R.string.hw_date,
            weekday,
            calendar.get(Calendar.DAY_OF_MONTH),
            months[calendar.get(Calendar.MONTH)],
        )
    }

    /** «1 дело», «2 дела», «5 дел» — как deeds() в приложении. */
    fun deeds(context: Context, count: Int): String {
        val mod100 = count % 100
        val mod10 = count % 10
        val form = when {
            mod100 in 11..14 -> R.string.hw_deeds_many
            mod10 == 1 -> R.string.hw_deeds_one
            mod10 in 2..4 -> R.string.hw_deeds_few
            else -> R.string.hw_deeds_many
        }
        return context.getString(form, count)
    }

    private const val MAX_SIZES = 4
}
