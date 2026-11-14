package com.example.local_assistant

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // «Открыть» у результата карточки расширения (ADR-024): копия во
        // временной папке и FileProvider только на чтение. Путь вне папок
        // приложения не открывается.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tridot/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "open") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                val main = Handler(Looper.getMainLooper())
                Thread {
                    val uri = try {
                        shareCopy(path)
                    } catch (error: Exception) {
                        null
                    }
                    main.post {
                        if (uri == null) {
                            result.success(false)
                        } else {
                            result.success(view(uri.first, uri.second))
                        }
                    }
                }.start()
            }
    }

    /** Копия [path] в cache/tridot-open и её адрес для других приложений. */
    private fun shareCopy(path: String): Pair<android.net.Uri, String>? {
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
        val copy = File(folder, source.name)
        source.copyTo(copy, overwrite = true)
        val extension = source.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
        return Pair(FileProvider.getUriForFile(this, "$packageName.files", copy), mime)
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
