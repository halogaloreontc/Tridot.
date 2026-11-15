package com.example.local_assistant

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Канал `tridot/links` (ADR-030): своя страница погоды в браузере и
 * приложение погоды. Только https, только по просьбе человека; сам канал в
 * сеть не ходит — страницу грузит браузер.
 *
 * Общей категории «приложение погоды» у Android нет, поэтому список —
 * известные пакеты из `<queries>` манифеста, которые установлены, плюс
 * системный выбор «Другое…» (ACTION_PICK_ACTIVITY). Чтобы выбранное потом
 * открывалось и подписывалось на Android 11+, в `<queries>` есть запрос
 * MAIN/LAUNCHER — видны приложения с иконкой на рабочем столе;
 * QUERY_ALL_PACKAGES не нужен.
 */
class LinksChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private var pendingPick: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, "tridot/links").setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                "weatherApps" -> result.success(weatherApps())
                "pickApp" -> pickApp(result)
                "openApp" -> result.success(openApp(call.argument<String>("package")))
                else -> result.notImplemented()
            }
        }
    }

    private val packages: PackageManager get() = activity.packageManager

    /** Только https с адресом сайта и без логина в адресе. */
    private fun openUrl(url: String?): Boolean {
        if (url == null || url.length > 2048) return false
        val uri = Uri.parse(url)
        if (!"https".equals(uri.scheme, ignoreCase = true) ||
            uri.host.isNullOrEmpty() ||
            uri.userInfo != null
        ) {
            return false
        }
        val intent = Intent(Intent.ACTION_VIEW, uri)
            .addCategory(Intent.CATEGORY_BROWSABLE)
        return try {
            activity.startActivity(intent)
            true
        } catch (error: ActivityNotFoundException) {
            false
        }
    }

    private fun label(packageName: String): String? = try {
        @Suppress("DEPRECATION")
        val info = packages.getApplicationInfo(packageName, 0)
        packages.getApplicationLabel(info).toString()
    } catch (error: PackageManager.NameNotFoundException) {
        null
    }

    /** Установленные приложения погоды из известного списка. */
    private fun weatherApps(): List<Map<String, String>> = KNOWN
        .filter { packages.getLaunchIntentForPackage(it.first) != null }
        .map { mapOf("id" to it.first, "label" to (label(it.first) ?: it.second)) }

    /** Системный выбор приложения; ответ — в [onActivityResult]. */
    private fun pickApp(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.success(null)
            return
        }
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val pick = Intent(Intent.ACTION_PICK_ACTIVITY)
            .putExtra(Intent.EXTRA_INTENT, launcher)
            .putExtra(Intent.EXTRA_TITLE, "Приложение погоды")
        pendingPick = result
        try {
            activity.startActivityForResult(pick, PICK_REQUEST)
        } catch (error: ActivityNotFoundException) {
            pendingPick = null
            result.success(null)
        }
    }

    /** `true` — это был ответ на [pickApp]. Сохраняются только пакет и подпись. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val packageName = data?.component?.packageName
        if (resultCode != Activity.RESULT_OK || packageName == null) {
            result.success(null)
            return true
        }
        result.success(mapOf("id" to packageName, "label" to (label(packageName) ?: packageName)))
        return true
    }

    private fun openApp(packageName: String?): Boolean {
        if (packageName.isNullOrEmpty() || packageName.length > 200) return false
        val intent = packages.getLaunchIntentForPackage(packageName) ?: return false
        return try {
            activity.startActivity(intent)
            true
        } catch (error: ActivityNotFoundException) {
            false
        } catch (error: SecurityException) {
            false
        }
    }

    companion object {
        private const val PICK_REQUEST = 4730

        /**
         * Известные приложения погоды (пакет, подпись по умолчанию). Данные, а
         * не обещание: каждый пакет нужно проверить на устройстве. Тот же
         * список — в `<queries>` манифеста.
         */
        val KNOWN = listOf(
            "com.google.android.apps.weather" to "Погода Google",
            "com.sec.android.daemonapp" to "Погода Samsung",
            "com.miui.weather2" to "Погода Xiaomi",
            "com.huawei.android.totemweather" to "Погода Huawei",
            "com.coloros.weather2" to "Погода OPPO",
            "com.oplus.weather" to "Погода OPPO",
            "ru.yandex.weatherplugin" to "Яндекс Погода",
            "ru.gismeteo.gismeteo" to "Gismeteo",
            "com.accuweather.android" to "AccuWeather",
        )
    }
}
