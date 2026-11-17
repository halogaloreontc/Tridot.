package com.example.local_assistant.media

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Конвертер звука и видео средствами телефона (ADR-026). Договор тот же,
 * что у macOS (lib/core/skills/converter/platform_media_job.dart):
 *
 * - `tridot/media`: `capabilities` → `{targets, video1080, api}`;
 *   `start {id, input, output, target, audioKbps?, videoRes?,
 *   videoQuality?, jpegQuality?}` → `null` сразу (неверный путь или цель —
 *   PlatformException с кодом); `cancel {id}` — можно звать сколько угодно;
 * - `tridot/media/events`: `{id, progress}` (0..1 или `null`, не чаще 4
 *   раз в секунду), затем ровно одно `{id, done: true}` или
 *   `{id, error: код}`.
 *
 * Пути — только из папок приложения (те же корни, что у «Открыть»):
 * наружу уходят только коды ошибок, без путей и текстов исключений.
 */
class MediaChannel private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private val jobs = ConcurrentHashMap<String, MediaJob>()
    private val executor: ExecutorService = Executors.newFixedThreadPool(2) { r ->
        Thread(r, "tridot-media").also { it.isDaemon = true }
    }
    private val media3 = Media3Thread()
    private var events: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Опрос кодировщиков — не на главном потоке и не в очереди задач.
            "capabilities" -> Thread({
                val caps = try {
                    capabilities()
                } catch (error: Exception) {
                    null
                }
                main.post { result.success(caps) }
            }, "tridot-media-caps").start()
            "start" -> start(call, result)
            "cancel" -> {
                val id = call.argument<String>("id")
                if (id != null) jobs[id]?.cancelled?.set(true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val input = call.argument<String>("input")?.let { allowed(it) }
        val output = call.argument<String>("output")?.let { allowed(it) }
        val target = call.argument<String>("target")
        if (id == null || input == null || output == null || target == null) {
            result.error(MediaCodes.FAILED, null, null)
            return
        }
        if (target !in supported()) {
            result.error(MediaCodes.UNSUPPORTED, null, null)
            return
        }
        if (jobs.containsKey(id)) {
            result.error(MediaCodes.FAILED, null, null)
            return
        }
        val request = MediaRequest(
            id = id,
            input = input,
            output = output,
            target = target,
            audioKbps = Presets.audioKbps(call.argument<Int>("audioKbps")),
            videoRes = Presets.videoRes(call.argument<String>("videoRes")),
            videoQuality = call.argument<String>("videoQuality")
                ?.takeIf { it in Presets.VIDEO_QUALITY } ?: "mid",
            jpegQuality = Presets.jpegQuality(call.argument<Int>("jpegQuality")),
        )
        val job = MediaJob(context, request, media3)
        jobs[id] = job
        try {
            executor.execute { runJob(job) }
        } catch (error: RejectedExecutionException) {
            jobs.remove(id)
            result.error(MediaCodes.FAILED, null, null)
            return
        }
        result.success(null)
    }

    private fun runJob(job: MediaJob) {
        val id = job.request.id
        var last = 0L
        var lastValue: Double? = -1.0
        val code = job.run { value ->
            val now = SystemClock.elapsedRealtime()
            if (now - last < 250 || value == lastValue || job.cancelled.get()) return@run
            last = now
            lastValue = value
            send(mapOf("id" to id, "progress" to value))
        }
        jobs.remove(id)
        send(
            if (code == null) {
                mapOf("id" to id, "done" to true)
            } else {
                mapOf("id" to id, "error" to code)
            },
        )
    }

    private fun send(event: Map<String, Any?>) {
        main.post { events?.success(event) }
    }

    /** Файл [path] внутри папок приложения; иначе `null`. */
    private fun allowed(path: String): File? {
        val file = File(path)
        if (!file.isAbsolute) return null
        val canonical = try {
            file.canonicalFile
        } catch (error: Exception) {
            return null
        }
        val roots = listOf(File(context.dataDir, "app_flutter/assistant"), context.cacheDir)
            .map { it.canonicalFile }
        return if (roots.any { canonical.path.startsWith(it.path + File.separator) }) canonical else null
    }

    /** Цели, которые этот телефон делает. */
    private fun supported(): Set<String> {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return buildSet {
            add(MediaTargets.WAV)
            add(MediaTargets.FRAME_JPEG)
            add(MediaTargets.FRAME_PNG)
            if (Mp3Native.loaded) add(MediaTargets.MP3)
            if (hasEncoder(list, MediaFormat.MIMETYPE_AUDIO_AAC)) add(MediaTargets.M4A)
            if (hasEncoder(list, MediaFormat.MIMETYPE_VIDEO_AVC) &&
                hasEncoder(list, MediaFormat.MIMETYPE_AUDIO_AAC)
            ) {
                add(MediaTargets.MP4)
            }
        }
    }

    private fun capabilities(): Map<String, Any?> {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return mapOf(
            "targets" to supported().toList(),
            "video1080" to encodes1080(list),
            "api" to Build.VERSION.SDK_INT,
        )
    }

    private fun hasEncoder(list: MediaCodecList, mime: String): Boolean =
        list.codecInfos.any { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }

    /** Есть кодировщик H.264, который умеет 1920×1080 (или 1080×1920). */
    private fun encodes1080(list: MediaCodecList): Boolean =
        list.codecInfos.any { info ->
            info.isEncoder && info.supportedTypes.any { type ->
                type.equals(MediaFormat.MIMETYPE_VIDEO_AVC, ignoreCase = true) &&
                    sizeOk(info, type)
            }
        }

    private fun sizeOk(info: MediaCodecInfo, type: String): Boolean = try {
        val video = info.getCapabilitiesForType(type).videoCapabilities
        video != null && (video.isSizeSupported(1920, 1080) || video.isSizeSupported(1080, 1920))
    } catch (error: Exception) {
        false
    }

    private fun dispose() {
        for (job in jobs.values) job.cancelled.set(true)
        executor.shutdown()
        media3.quit()
    }

    companion object {
        /** Регистрирует каналы для движка Flutter; вернёт функцию уборки. */
        fun register(context: Context, messenger: BinaryMessenger): () -> Unit {
            val channel = MediaChannel(context.applicationContext)
            MethodChannel(messenger, "tridot/media").setMethodCallHandler(channel)
            EventChannel(messenger, "tridot/media/events").setStreamHandler(channel)
            return { channel.dispose() }
        }
    }
}
