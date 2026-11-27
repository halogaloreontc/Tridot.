package com.example.local_assistant.downloads

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Канал `tridot/downloads`: служба загрузки в фоне ([DownloadService]). */
class DownloadsChannel(private val context: Context, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "tridot/downloads").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "update" -> {
                        DownloadService.update(
                            context,
                            call.argument<String>("title") ?: "Скачивается модель",
                            (call.argument<Number>("received") ?: 0).toLong(),
                            (call.argument<Number>("total") ?: 0).toLong(),
                        )
                        result.success(true)
                    }
                    "stop" -> {
                        DownloadService.stop(context)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                // Службу не запустили (Android запретил из фона) — загрузка
                // идёт как раньше, пока приложение открыто.
                result.success(false)
            }
        }
    }
}
