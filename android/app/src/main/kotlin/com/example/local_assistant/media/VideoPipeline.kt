package com.example.local_assistant.media

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Поток с Looper для Media3 Transformer: все его вызовы — здесь. */
class Media3Thread {
    private val thread = HandlerThread("tridot-media3").also { it.start() }
    val handler = Handler(thread.looper)

    fun quit() {
        thread.quitSafely()
    }
}

/**
 * Видео в MP4 (H.264 + AAC) через androidx.media3 Transformer (ADR-026): он
 * сам ведёт MediaCodec и MediaMuxer, поворот и особенности кодеков.
 * Размер — длинная сторона не больше предустановки, меньшее не
 * растягивается; битрейт — по [Presets].
 */
@OptIn(markerClass = [UnstableApi::class])
class VideoPipeline(
    private val context: Context,
    private val job: MediaJob,
    private val media3: Media3Thread,
    private val progress: MediaProgress,
) {
    private val request = job.request

    fun run() {
        val (width, height, fps) = probe()
        val res = request.videoRes
        val size = Presets.scaledSize(res, width, height)
        val outW = size?.first ?: width
        val outH = size?.second ?: height
        val q = Presets.qualityIndex(request.videoQuality)
        val videoBitrate = Presets.videoBitrate(res, request.videoQuality, outW, outH, fps)
        val audioBitrate = Presets.VIDEO_AUDIO_KBPS[q] * 1000
        val done = CountDownLatch(1)
        val failure = AtomicReference<String?>(null)
        val running = AtomicReference<Transformer?>(null)
        val handler = media3.handler
        handler.post {
            try {
                val encoders = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder().setBitrate(videoBitrate).build(),
                    )
                    .setRequestedAudioEncoderSettings(
                        AudioEncoderSettings.Builder().setBitrate(audioBitrate).build(),
                    )
                    .build()
                val transformer = Transformer.Builder(context)
                    .setLooper(handler.looper)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoders)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            done.countDown()
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            failure.set(codeOf(exportException))
                            done.countDown()
                        }
                    })
                    .build()
                val effects = if (size == null) {
                    Effects.EMPTY
                } else {
                    Effects(
                        listOf(),
                        listOf(
                            Presentation.createForWidthAndHeight(
                                outW,
                                outH,
                                Presentation.LAYOUT_SCALE_TO_FIT,
                            ),
                        ),
                    )
                }
                val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(request.input)))
                    .setEffects(effects)
                    .build()
                running.set(transformer)
                transformer.start(item, request.output.path)
                poll(transformer, done)
            } catch (error: Exception) {
                failure.set(MediaCodes.FAILED)
                done.countDown()
            }
        }
        try {
            while (!done.await(WAIT_MS, TimeUnit.MILLISECONDS)) {
                if (job.cancelled.get()) {
                    stop(running)
                    throw MediaFail(MediaCodes.CANCELLED)
                }
            }
        } catch (error: InterruptedException) {
            stop(running)
            throw MediaFail(MediaCodes.CANCELLED)
        }
        failure.get()?.let { throw MediaFail(it) }
    }

    /** Отмена экспорта на потоке Media3; ждём её, чтобы файл больше не писался. */
    private fun stop(running: AtomicReference<Transformer?>) {
        val stopped = CountDownLatch(1)
        media3.handler.post {
            try {
                running.get()?.cancel()
            } finally {
                stopped.countDown()
            }
        }
        try {
            stopped.await(2, TimeUnit.SECONDS)
        } catch (error: InterruptedException) {
            // Уходим: временный файл уберёт и Dart.
        }
    }

    /** Ход работы раз в 250 мс, пока экспорт не закончился. */
    private fun poll(transformer: Transformer, done: CountDownLatch) {
        val holder = ProgressHolder()
        val tick = object : Runnable {
            override fun run() {
                if (done.count == 0L || job.cancelled.get()) return
                val state = transformer.getProgress(holder)
                if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                    progress.report((holder.progress / 100.0).coerceIn(0.0, 0.99))
                } else if (state != Transformer.PROGRESS_STATE_NOT_STARTED) {
                    progress.report(null)
                }
                media3.handler.postDelayed(this, WAIT_MS)
            }
        }
        media3.handler.postDelayed(tick, WAIT_MS)
    }

    /** Ширина и высота на экране (с поворотом) и частота кадров. */
    private fun probe(): Triple<Int, Int, Float> {
        val retriever = MediaMetadataRetriever()
        try {
            try {
                retriever.setDataSource(request.input.path)
            } catch (error: Exception) {
                throw MediaFail(MediaCodes.MEDIA_OPEN)
            }
            if (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) != "yes") {
                throw MediaFail(MediaCodes.NO_STREAM)
            }
            fun int(key: Int): Int = retriever.extractMetadata(key)?.toIntOrNull() ?: 0
            var w = int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            var h = int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val rotation = int(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            if (rotation == 90 || rotation == 270) {
                val t = w
                w = h
                h = t
            }
            // Частота кадров: число кадров / длительность (Android 9+).
            var fps = 30f
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val frames = int(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                val ms = int(MediaMetadataRetriever.METADATA_KEY_DURATION)
                if (frames > 0 && ms > 0) fps = frames * 1000f / ms
            }
            return Triple(w, h, fps)
        } finally {
            try {
                retriever.release()
            } catch (error: Exception) {
                // Молча.
            }
        }
    }

    companion object {
        private const val WAIT_MS = 250L

        fun codeOf(error: ExportException): String = when (error.errorCode) {
            ExportException.ERROR_CODE_IO_FILE_NOT_FOUND -> MediaCodes.MISSING
            ExportException.ERROR_CODE_IO_NO_PERMISSION -> MediaCodes.DISK
            ExportException.ERROR_CODE_DECODER_INIT_FAILED,
            ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            -> MediaCodes.MEDIA_OPEN
            ExportException.ERROR_CODE_DECODING_FAILED -> MediaCodes.MEDIA
            ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
            ExportException.ERROR_CODE_ENCODING_FAILED,
            ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED,
            -> MediaCodes.ENCODER
            else -> if (MediaJob.noSpace(error)) MediaCodes.DISK else MediaCodes.FAILED
        }
    }
}
