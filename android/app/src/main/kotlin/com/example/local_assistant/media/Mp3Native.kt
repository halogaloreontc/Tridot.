package com.example.local_assistant.media

import java.nio.ByteBuffer

/**
 * Встроенный кодировщик MP3 (ADR-026): libtridot_mp3 — LAME 3.100 и тонкая
 * обёртка (packages/tridot_lame, LGPL-2.0-or-later), отдельная разделяемая
 * библиотека в APK. Методы регистрирует JNI_OnLoad библиотеки
 * (src/tridot_lame_jni.c); имена и сигнатуры должны совпадать с ним.
 * Ошибки — отрицательные числа, у [open] — 0.
 */
object Mp3Native {
    /** Библиотека загрузилась и это та версия LAME. */
    val loaded: Boolean by lazy {
        try {
            System.loadLibrary("tridot_mp3")
            version() == "3.100"
        } catch (error: Throwable) {
            false
        }
    }

    @JvmStatic external fun open(rate: Int, channels: Int, kbps: Int, outRate: Int): Long

    @JvmStatic external fun encode(
        handle: Long,
        pcm: ByteBuffer,
        frames: Int,
        channels: Int,
        out: ByteBuffer,
    ): Int

    @JvmStatic external fun flush(handle: Long, out: ByteBuffer): Int

    @JvmStatic external fun lametag(handle: Long, out: ByteBuffer): Int

    @JvmStatic external fun outRate(handle: Long): Int

    @JvmStatic external fun close(handle: Long)

    @JvmStatic external fun version(): String

    /**
     * Размер буфера MP3 для [frames] кадров входа [inRate] при частоте MP3
     * [outRate] (как tl_out_cap_rate): при пересэмплировании вверх
     * (8 кГц на 320 кбит/с → 44,1 кГц) байт выходит больше.
     */
    fun outCap(frames: Int, inRate: Int, outRate: Int): Int {
        val scaled = if (outRate > inRate) {
            (frames.toLong() * outRate + inRate - 1) / inRate
        } else {
            frames.toLong()
        }
        return (scaled + scaled / 4 + 7200).toInt()
    }
}
