package com.example.local_assistant.media

/**
 * Предустановки качества — копия таблицы ConvertQuality
 * (lib/core/skills/converter/convert_quality.dart). Тест
 * test/skills/converter/presets_parity_test.dart читает этот файл и
 * сверяет числа: меняются они в обоих местах сразу.
 */
object Presets {
    /** Битрейт звука mp3 и m4a, кбит/с. */
    val AUDIO_KBPS = intArrayOf(128, 192, 256, 320)
    const val AUDIO_KBPS_DEFAULT = 192

    /** Качество JPEG кадра. */
    val JPEG_QUALITY = intArrayOf(95, 85, 75, 60)
    const val JPEG_QUALITY_DEFAULT = 85

    /** Качество видео: высокое, среднее, экономное. */
    val VIDEO_QUALITY = arrayOf("high", "mid", "eco")

    /** Битрейт видео H.264, кбит/с, по размеру: высокое, среднее, экономное. */
    val VIDEO_KBPS = mapOf(
        "1080" to intArrayOf(8000, 5000, 3000),
        "720" to intArrayOf(5000, 3000, 1800),
        "480" to intArrayOf(2500, 1500, 900),
        "src" to intArrayOf(8000, 4000, 2000),
    )

    /** Битрейт звука AAC внутри видео, кбит/с. */
    val VIDEO_AUDIO_KBPS = intArrayOf(192, 160, 128)

    /** Длинная сторона кадра по размеру видео. */
    val LONG_SIDE = mapOf("1080" to 1920, "720" to 1280, "480" to 854)

    /** «Как в исходнике»: бит на пиксель кадра (высокое, среднее, экономное). */
    val PIXEL_FACTOR = doubleArrayOf(0.13, 0.08, 0.05)

    fun qualityIndex(quality: String?): Int = when (quality) {
        "high" -> 0
        "eco" -> 2
        else -> 1
    }

    fun audioKbps(value: Int?): Int =
        if (value != null && value in AUDIO_KBPS) value else AUDIO_KBPS_DEFAULT

    fun jpegQuality(value: Int?): Int =
        if (value != null && value in JPEG_QUALITY) value else JPEG_QUALITY_DEFAULT

    fun videoRes(value: String?): String =
        if (value != null && value in VIDEO_KBPS) value else "src"

    /**
     * Битрейт видео, бит/с. «Как в исходнике» — по числу пикселей и кадров
     * в секунду, но не больше строки 1080p.
     */
    fun videoBitrate(res: String, quality: String?, width: Int, height: Int, fps: Float): Int {
        val q = qualityIndex(quality)
        val row = VIDEO_KBPS[res] ?: VIDEO_KBPS.getValue("src")
        if (res != "src" || width <= 0 || height <= 0) return row[q] * 1000
        val rate = if (fps in 1f..240f) fps else 30f
        val byPixels = width.toDouble() * height * rate * PIXEL_FACTOR[q]
        val cap = VIDEO_KBPS.getValue("1080")[q] * 1000.0
        return byPixels.coerceIn(300_000.0, cap).toInt()
    }

    /**
     * Размер кадра для [res]: длинная сторона не больше предустановки,
     * пропорции те же, стороны чётные, меньшее видео не растягивается.
     * `null` — оставить как есть.
     */
    fun scaledSize(res: String, width: Int, height: Int): Pair<Int, Int>? {
        val side = LONG_SIDE[res] ?: return null
        val long = maxOf(width, height)
        if (width <= 0 || height <= 0 || long <= side) return null
        val scale = side.toDouble() / long
        fun even(v: Double): Int = maxOf(2, (v / 2).toInt() * 2)
        return Pair(even(width * scale), even(height * scale))
    }
}
