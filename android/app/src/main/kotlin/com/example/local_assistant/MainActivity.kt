package com.example.local_assistant

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.example.local_assistant.downloads.DownloadsChannel
import com.example.local_assistant.homescreen.HomeScreenChannel
import com.example.local_assistant.homescreen.HomeScreenWidgets
import com.example.local_assistant.media.MediaChannel
import com.example.local_assistant.notify.NotifyChannel
import com.example.local_assistant.voice.VoiceChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var disposeMedia: (() -> Unit)? = null
    private var disposeVoice: (() -> Unit)? = null
    private var notify: NotifyChannel? = null
    private var links: LinksChannel? = null
    private var incoming: IncomingLinkChannel? = null
    private var homeScreen: HomeScreenChannel? = null
    private var fontScale = 0f

    /**
     * Активность восстановлена после остановки процесса (из «Недавних»
     * или по значку): система снова приносит намерение, которым задачу
     * когда-то открыли, — микрофон, поле или чат задачи с виджета и
     * уведомления, ссылку склада. Каналы его не исполняют повторно.
     */
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // До super.onCreate: каналы создаются внутри него (configureFlutterEngine).
        restored = savedInstanceState != null
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Конвертер звука и видео средствами телефона (ADR-026): MediaCodec,
        // Media3 Transformer и встроенный LAME; работа — в своих потоках.
        disposeMedia = MediaChannel.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // Сейф (ADR-025): ключ устройства в Android Keystore, запрет снимков
        // экрана на экранах ПИН-кода и кода восстановления; вход в
        // приложение по отпечатку / Face ID.
        VaultKeyChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        DeviceAuthChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        // Уведомления о задачах и будильник в «Часах» (ADR-029): только на
        // устройстве, без сети.
        notify = NotifyChannel(this, flutterEngine.dartExecutor.binaryMessenger, restored)
        // Своя страница и приложение погоды (ADR-030): открывает система,
        // канал в сеть не ходит.
        links = LinksChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        // Склад (ADR-031): секреты подключений — AES-GCM ключом Keystore;
        // «Открыть в Tridot» и «Поделиться» ссылкой или QR — в окно
        // подтверждения.
        SecretsChannel(flutterEngine.dartExecutor.binaryMessenger)
        incoming = IncomingLinkChannel(this, flutterEngine.dartExecutor.binaryMessenger, restored)
        // Виджеты рабочего стола (ADR-034): снимок «Сегодня», очередь
        // отметок «выполнено», «Что сделать?» и микрофон с виджета.
        homeScreen = HomeScreenChannel(this, flutterEngine.dartExecutor.binaryMessenger, restored)
        fontScale = resources.configuration.fontScale
        // Голосовой ввод распознаванием телефона (ADR-023): только
        // createOnDeviceSpeechRecognizer, звук не уходит с устройства.
        disposeVoice = VoiceChannel.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // Загрузка моделей в фоне (ADR-046): служба держит процесс, пока
        // Dart качает модель.
        DownloadsChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // «Открыть» у результата карточки расширения (ADR-024): копия во
        // временной папке и FileProvider только на чтение. Путь вне папок
        // приложения не открывается.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tridot/files")
            .setMethodCallHandler { call, result ->
                // "share" — «Поделиться» файлом (ADR-045: непонятые фразы,
                // которые человек сам просмотрел); те же корни, что у "open".
                if (call.method != "open" && call.method != "share") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                // Имя для показа (вложение: на диске оно `<id>-<n>.ext`).
                val name = call.argument<String>("name")
                if (path == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                val main = Handler(Looper.getMainLooper())
                Thread {
                    val uri = try {
                        shareCopy(path, name)
                    } catch (error: Exception) {
                        null
                    }
                    main.post {
                        if (uri == null) {
                            result.success(false)
                        } else {
                            result.success(
                                if (call.method == "share") send(uri.first) else view(uri.first, uri.second),
                            )
                        }
                    }
                }.start()
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        disposeMedia?.invoke()
        disposeMedia = null
        disposeVoice?.invoke()
        disposeVoice = null
        notify = null
        links = null
        incoming = null
        homeScreen?.dispose()
        homeScreen = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Сменили масштаб шрифта (Tridot сам перерисовывается — configChanges):
     * строки виджетов считаются по шрифту, их число нужно пересчитать.
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (newConfig.fontScale != fontScale) {
            fontScale = newConfig.fontScale
            HomeScreenWidgets.updateAll(this)
        }
    }

    /** Ответ системного выбора «Другое приложение…» (погода). */
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (links?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        notify?.onRequestPermissionsResult(requestCode)
    }

    /**
     * Ссылка склада, поле или микрофон виджета, нажатое уведомление или
     * строка виджета (чат задачи), пока приложение открыто.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (incoming?.onNewIntent(intent) == true) return
        if (homeScreen?.onNewIntent(intent) == true) return
        notify?.onNewIntent(intent)
    }

    /**
     * Копия [path] в cache/tridot-open и её адрес для других приложений.
     * [name] — имя копии для показа (без папок и запрещённых знаков);
     * нет или пустое — имя исходного файла.
     */
    private fun shareCopy(path: String, name: String?): Pair<android.net.Uri, String>? {
        val source = File(path).canonicalFile
        // Только папка помощника (getApplicationDocumentsDirectory() +
        // assistant: вложения и результаты карточек) и временная папка —
        // те же корни, что разрешает Dart. Настройки, базы и хранилище
        // паролей из dataDir наружу не отдаются никогда.
        val roots = listOf(File(dataDir, "app_flutter/assistant"), cacheDir)
            .map { it.canonicalFile }
        if (roots.none { source.path.startsWith(it.path + File.separator) }) {
            return null
        }
        if (!source.isFile) return null
        val shared = File(cacheDir, "tridot-open")
        shared.deleteRecursively()
        val folder = File(shared, UUID.randomUUID().toString())
        if (!folder.mkdirs()) return null
        val shown = name?.let { File(it).name }
            ?.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
            ?.trim()
            ?.take(120)
            ?.takeIf { it.isNotEmpty() && it != "." && it != ".." }
        val copy = File(folder, shown ?: source.name)
        source.copyTo(copy, overwrite = true)
        val extension = source.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
        return Pair(FileProvider.getUriForFile(this, "$packageName.files", copy), mime)
    }

    /** Системное «Поделиться» текстовым файлом [uri]: только чтение. */
    private fun send(uri: android.net.Uri): Boolean {
        val intent = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(Intent.createChooser(intent, null))
            true
        } catch (error: ActivityNotFoundException) {
            false
        }
    }

    private fun view(uri: android.net.Uri, mime: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(Intent.createChooser(intent, null))
            true
        } catch (error: ActivityNotFoundException) {
            false
        }
    }
}
