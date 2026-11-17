package com.example.local_assistant.media

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/** Коды ошибок — те же, что JobCodes в Dart (lib/core/jobs/job_runner.dart). */
object MediaCodes {
    const val MISSING = "missing"
    const val NO_STREAM = "noStream"
    const val MEDIA = "media"
    const val MEDIA_OPEN = "mediaOpen"
    const val ENCODER = "encoder"
    const val DISK = "disk"
    const val TOO_BIG = "tooBig"
    const val TOO_BIG_WAV = "tooBigWav"
    const val NO_MEMORY = "noMemory"
    const val UNSUPPORTED = "unsupported"
    const val CANCELLED = "cancelled"
    const val FAILED = "failed"
}

/** Ошибка задачи с готовым кодом [MediaCodes]. */
class MediaFail(val code: String) : Exception(code)

/** Что сделать: цель и качество уже проверены по [Presets]. */
data class MediaRequest(
    val id: String,
    val input: File,
    val output: File,
    val target: String,
    val audioKbps: Int,
    val videoRes: String,
    val videoQuality: String,
    val jpegQuality: Int,
)

/** Куда задача сообщает ход работы. */
fun interface MediaProgress {
    /** [value] 0..1 или `null` — неизвестно. */
    fun report(value: Double?)
}

/**
 * Одна задача: работает в своём потоке, флаг [cancelled] проверяется на
 * каждом буфере. Временный файл [MediaRequest.output] при ошибке и отмене
 * удаляется здесь; итоговое имя даёт Dart (JobPlacement.commitFile).
 */
class MediaJob(
    private val context: Context,
    val request: MediaRequest,
    private val media3: Media3Thread,
) {
    val cancelled = AtomicBoolean(false)

    fun checkCancelled() {
        if (cancelled.get()) throw MediaFail(MediaCodes.CANCELLED)
    }

    /** Выполняет задачу: `null` — готово, иначе код ошибки. */
    fun run(progress: MediaProgress): String? {
        return try {
            if (!request.input.isFile) throw MediaFail(MediaCodes.MISSING)
            request.output.delete()
            when (request.target) {
                MediaTargets.MP3, MediaTargets.M4A, MediaTargets.WAV ->
                    AudioPipeline(this, progress).run()
                MediaTargets.MP4 -> VideoPipeline(context, this, media3, progress).run()
                MediaTargets.FRAME_JPEG, MediaTargets.FRAME_PNG -> FramePipeline(this).run()
                else -> throw MediaFail(MediaCodes.UNSUPPORTED)
            }
            checkCancelled()
            if (!request.output.isFile || request.output.length() == 0L) {
                throw MediaFail(MediaCodes.FAILED)
            }
            null
        } catch (error: Throwable) {
            request.output.delete()
            val code = codeOf(error)
            // Без путей и текстов исключений: только вид ошибки.
            if (code != MediaCodes.CANCELLED) {
                Log.w(TAG, "${request.target}: $code (${error.javaClass.simpleName})")
            }
            if (cancelled.get()) MediaCodes.CANCELLED else code
        }
    }

    companion object {
        const val TAG = "TridotMedia"

        fun codeOf(error: Throwable): String = when (error) {
            is MediaFail -> error.code
            is FileNotFoundException -> MediaCodes.MISSING
            is IOException -> if (noSpace(error)) MediaCodes.DISK else MediaCodes.FAILED
            is OutOfMemoryError -> MediaCodes.NO_MEMORY
            else -> MediaCodes.FAILED
        }

        fun noSpace(error: Throwable): Boolean {
            var e: Throwable? = error
            while (e != null) {
                val text = e.message ?: ""
                if (text.contains("ENOSPC") || text.contains("No space")) return true
                e = e.cause
            }
            return false
        }
    }
}

/** Цели, которые делает телефон (значения поля target карточки). */
object MediaTargets {
    const val MP3 = "mp3"
    const val M4A = "m4a"
    const val WAV = "wav"
    const val MP4 = "mp4"
    const val FRAME_JPEG = "frame-jpeg"
    const val FRAME_PNG = "frame-png"
}
