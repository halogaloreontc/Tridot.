package com.example.local_assistant.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Распознавание речи средствами телефона (ADR-023): каналы `tridot/voice` и
 * `tridot/voice/events`.
 *
 * Только [SpeechRecognizer.createOnDeviceSpeechRecognizer] (Android 12+):
 * обычный `createSpeechRecognizer` может отправлять звук на серверы, поэтому
 * не вызывается нигде, даже запасным путём. EXTRA_PREFER_OFFLINE тоже не
 * используется: по документации он ничего не гарантирует. Нет распознавания
 * на устройстве — Dart выбирает Vosk, а не облако.
 *
 * Звук записывает системная служба распознавания, приложение его не
 * видит. Распознанный текст не пишется в журнал. Сеть бывает только у
 * системной загрузки языка ([download]) — после явного «Скачать».
 *
 * Все вызовы SpeechRecognizer — в главном потоке (так работает MethodChannel).
 */
class VoiceChannel private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var session: Int? = null

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> status(call.language(), result)
            "download" -> download(call.language(), result)
            "start" -> start(call.argument<Int>("session"), call.language(), result)
            "stop" -> {
                if (call.argument<Int>("session") == session) {
                    recognizer?.stopListening()
                }
                result.success(null)
            }
            "cancel" -> {
                if (call.argument<Int>("session") == session) release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun MethodCall.language(): String = argument<String>("language") ?: "ru-RU"

    private fun available(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    private fun intent(language: String): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
        }

    // ------------------------------------------------------------ язык

    private fun status(language: String, result: MethodChannel.Result) {
        val api = Build.VERSION.SDK_INT
        if (!available()) {
            result.success(mapOf("api" to api, "available" to false, "language" to "unsupported"))
            return
        }
        if (api < Build.VERSION_CODES.TIRAMISU) {
            result.success(mapOf("api" to api, "available" to true, "language" to "unknown"))
            return
        }
        checkSupport(language) { state ->
            result.success(mapOf("api" to api, "available" to true, "language" to state))
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun checkSupport(language: String, done: (String) -> Unit) {
        var answered = false
        val probe = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (error: Exception) {
            done("unknown")
            return
        }
        fun answer(state: String) {
            if (answered) return
            answered = true
            main.post { probe.destroy() }
            done(state)
        }
        main.postDelayed({ answer("unknown") }, 5000)
        try {
            probe.checkRecognitionSupport(
                intent(language),
                context.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        main.post { answer(stateOf(support, language)) }
                    }

                    override fun onError(error: Int) {
                        main.post { answer("unknown") }
                    }
                },
            )
        } catch (error: Exception) {
            answer("unknown")
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun stateOf(support: RecognitionSupport, language: String): String {
        val wanted = Locale.forLanguageTag(language).language
        fun has(tags: List<String>) = tags.any { Locale.forLanguageTag(it).language == wanted }
        // Язык только в списке «онлайн» — для нас не поддерживается.
        return when {
            has(support.installedOnDeviceLanguages) -> "installed"
            has(support.pendingOnDeviceLanguages) -> "pending"
            has(support.supportedOnDeviceLanguages) -> "supported"
            else -> "unsupported"
        }
    }

    private fun download(language: String, result: MethodChannel.Result) {
        if (!available() || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("unsupported")
            return
        }
        val probe = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (error: Exception) {
            result.success("unsupported")
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                downloadWithProgress(probe, language)
            } else {
                probe.triggerModelDownload(intent(language))
                main.postDelayed({ probe.destroy() }, 1000)
            }
            result.success("requested")
        } catch (error: Exception) {
            probe.destroy()
            result.success("error")
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun downloadWithProgress(probe: SpeechRecognizer, language: String) {
        fun send(state: String, value: Int? = null, end: Boolean = false) {
            main.post {
                val event = mutableMapOf<String, Any>("type" to "download", "state" to state)
                if (value != null) event["value"] = value
                events?.success(event)
                if (end) probe.destroy()
            }
        }
        probe.triggerModelDownload(
            intent(language),
            context.mainExecutor,
            object : ModelDownloadListener {
                override fun onProgress(completedPercent: Int) = send("progress", completedPercent)
                override fun onSuccess() = send("success", end = true)
                override fun onScheduled() = send("scheduled", end = true)
                override fun onError(error: Int) = send("error", error, end = true)
            },
        )
    }

    // ------------------------------------------------------------ речь

    private fun start(id: Int?, language: String, result: MethodChannel.Result) {
        if (id == null) {
            result.error("bad_args", null, null)
            return
        }
        release()
        if (!available()) {
            result.success(-1)
            return
        }
        val created = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (error: UnsupportedOperationException) {
            result.success(-1)
            return
        } catch (error: SecurityException) {
            result.success(-1)
            return
        }
        recognizer = created
        session = id
        created.setRecognitionListener(Listener(id))
        val request = intent(language).apply {
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // Знаки и заглавные: «?» помогает отличить вопрос от просьбы.
                putExtra(
                    RecognizerIntent.EXTRA_ENABLE_FORMATTING,
                    RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY,
                )
                // Звёздочки вместо слов сломали бы разбор фразы.
                putExtra(RecognizerIntent.EXTRA_MASK_OFFENSIVE_WORDS, false)
            }
        }
        try {
            created.startListening(request)
            result.success(0)
        } catch (error: Exception) {
            release()
            result.success(-1)
        }
    }

    private fun release() {
        val current = recognizer
        recognizer = null
        session = null
        if (current != null) {
            try {
                current.cancel()
            } catch (error: Exception) {
                // Уже остановлен.
            }
            current.destroy()
        }
    }

    private fun emit(id: Int, type: String, text: String? = null, code: Int? = null) {
        if (session != id) return
        val event = mutableMapOf<String, Any>("session" to id, "type" to type)
        if (text != null) event["text"] = text
        if (code != null) event["code"] = code
        events?.success(event)
    }

    /** Итог сессии: событие, затем «end», затем распознаватель уничтожен. */
    private fun finish(id: Int) {
        if (session != id) return
        emit(id, "end")
        release()
    }

    private inner class Listener(private val id: Int) : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            val text = first(partialResults) ?: return
            emit(id, "partial", text = text)
        }

        override fun onResults(results: Bundle?) {
            emit(id, "final", text = first(results) ?: "")
            finish(id)
        }

        override fun onError(error: Int) {
            // После отмены сессия уже сброшена: ошибка (обычно ERROR_CLIENT)
            // не уходит.
            emit(id, "error", code = error)
            finish(id)
        }

        private fun first(bundle: Bundle?): String? =
            bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
    }

    companion object {
        /** Регистрирует каналы; возвращает освобождение. */
        fun register(context: Context, messenger: BinaryMessenger): () -> Unit {
            val channel = VoiceChannel(context)
            val method = MethodChannel(messenger, "tridot/voice")
            val events = EventChannel(messenger, "tridot/voice/events")
            method.setMethodCallHandler(channel)
            events.setStreamHandler(channel)
            return {
                channel.release()
                method.setMethodCallHandler(null)
                events.setStreamHandler(null)
            }
        }
    }
}
