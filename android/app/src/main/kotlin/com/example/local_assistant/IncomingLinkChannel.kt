package com.example.local_assistant

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/**
 * Входящие ссылки склада (ADR-031): «Открыть в Tridot»
 * (`tridot://connect?…`) и «Поделиться» текстом или снимком экрана с QR.
 * Канал `tridot/incoming` только передаёт текст ссылки или путь к копии
 * картинки в cache/tridot-incoming; разбор и подтверждение — в Dart.
 * Прочитанное намерение очищается: код одноразовый и не должен
 * повториться при повороте экрана или возврате в приложение. Запуск из
 * «Недавних» (FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) и восстановление после
 * остановки процесса приносят прежнее намерение заново — его не читаем, а
 * намерение активности заменяем пустым (как MainActivity.handleLink в
 * DepotDesk). Картинку берём только по content:// — file:// мог бы
 * указать на собственные файлы Tridot.
 */
class IncomingLinkChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "tridot/incoming")
    private val main = Handler(Looper.getMainLooper())
    private var pending: Map<String, String>? = null

    init {
        pending = read(activity.intent)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initial" -> {
                    result.success(pending)
                    pending = null
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Новое намерение, пока приложение открыто. `true` — оно наше. */
    fun onNewIntent(intent: Intent): Boolean {
        val item = read(intent) ?: return false
        channel.invokeMethod("incoming", item)
        return true
    }

    private fun read(intent: Intent?): Map<String, String>? {
        if (intent == null) return null
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        val item = when (intent.action) {
            Intent.ACTION_VIEW -> link(intent.data)
            Intent.ACTION_SEND -> shared(intent)
            else -> null
        }
        if (item != null) {
            // Код одноразовый: из намерения его убираем сразу.
            intent.data = null
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_STREAM)
            intent.action = Intent.ACTION_MAIN
            if (intent === activity.intent) {
                activity.intent = Intent(activity, MainActivity::class.java)
            }
        }
        return item
    }

    private fun link(uri: Uri?): Map<String, String>? {
        if (uri == null) return null
        val text = uri.toString()
        if (text.length > MAX || uri.scheme?.lowercase() != "tridot") return null
        return mapOf("kind" to "link", "text" to text)
    }

    private fun shared(intent: Intent): Map<String, String>? {
        val type = intent.type ?: return null
        if (type == "text/plain") {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim() ?: return null
            if (text.isEmpty() || text.length > MAX) return null
            return mapOf("kind" to "text", "text" to text)
        }
        if (type.startsWith("image/")) {
            @Suppress("DEPRECATION")
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return null
            if (uri.scheme?.lowercase() != "content") return null
            val copy = copyImage(uri) ?: return null
            return mapOf("kind" to "image", "path" to copy)
        }
        return null
    }

    /** Копия картинки (не больше 10 МБ) в cache/tridot-incoming. */
    private fun copyImage(uri: Uri): String? = try {
        val folder = File(activity.cacheDir, "tridot-incoming")
        folder.deleteRecursively()
        folder.mkdirs()
        val target = File(folder, UUID.randomUUID().toString() + ".img")
        activity.contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > MAX_IMAGE) throw IllegalStateException("big")
                    output.write(buffer, 0, read)
                }
            }
        } ?: return null
        target.path
    } catch (error: Exception) {
        null
    }

    companion object {
        private const val MAX = 2048
        private const val MAX_IMAGE = 10L * 1024 * 1024
    }
}
