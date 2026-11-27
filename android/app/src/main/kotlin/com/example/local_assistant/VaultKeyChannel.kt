package com.example.local_assistant

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.Arrays
import java.util.UUID
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/**
 * Ключ устройства для сейфа (ADR-025): HMAC-SHA256 ключом Android Keystore,
 * который не покидает защищённое железо (StrongBox, если есть, иначе TEE).
 * Наружу уходит только ответ HMAC; сам ключ не экспортируется никогда.
 *
 * Ключ слота «биометрия» создаётся с проверкой личности на каждое
 * использование: Keystore выдаёт ответ только внутри системного запроса
 * отпечатка, лица или блокировки экрана (BiometricPrompt с CryptoObject) —
 * это криптографическая привязка, а не флажок в интерфейсе. Только
 * Android 11+ (API 30): там один запрос принимает и сильную биометрию, и
 * PIN-код экрана.
 *
 * Ни ПИН-кода сейфа, ни кода восстановления сюда не приходит: для ПИН-кода
 * в сообщении — уже выведенное Argon2id значение. Входные байты
 * затираются.
 */
class VaultKeyChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "tridot/vault_key").setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "bioAvailable" -> result.success(bioAvailable())
            "create" -> background(result) {
                create(call.argument<Boolean>("userAuth") == true)
            }
            "mac" -> mac(call, result)
            "delete" -> background(result) {
                val alias = call.argument<String>("alias") ?: ""
                keyStore().deleteEntry(alias)
                null
            }
            "secureWindow" -> {
                if (call.argument<Boolean>("on") == true) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    /** Сильная биометрия или блокировка экрана в одном запросе — API 30+. */
    private fun bioAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val manager = activity.getSystemService(BiometricManager::class.java) ?: return false
        val allowed = BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
        return manager.canAuthenticate(allowed) == BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun create(userAuth: Boolean): String {
        if (userAuth && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            throw VaultKeyFailure("UNAVAILABLE")
        }
        val alias = "tridot-vault-" + UUID.randomUUID().toString()
        val strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
        if (strongBox) {
            // StrongBox у многих телефонов не держит HMAC-SHA256: ключ не
            // создаётся (ProviderException, не только
            // StrongBoxUnavailableException) или создаётся, но не считает.
            // Тогда — ключ в TEE: он тоже не покидает защищённое железо.
            try {
                generate(alias, userAuth, true)
                if (userAuth || works(alias)) return alias
            } catch (error: Exception) {
                // Ниже — без StrongBox.
            }
            try {
                keyStore().deleteEntry(alias)
            } catch (error: Exception) {
                // Ключа нет — нечего удалять.
            }
        }
        generate(alias, userAuth, false)
        return alias
    }

    /** Ключ без проверки личности считает HMAC: пробное сообщение. */
    private fun works(alias: String): Boolean = try {
        val key = keyStore().getKey(alias, null) as SecretKey
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(key)
        mac.doFinal(ByteArray(32)).size == 32
    } catch (error: Exception) {
        false
    }

    private fun generate(alias: String, userAuth: Boolean, strongBox: Boolean) {
        val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        if (userAuth && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationRequired(true)
            builder.setUserAuthenticationParameters(
                0,
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
            )
            // Новый отпечаток или снятая блокировка экрана сбрасывают ключ:
            // чужой отпечаток, добавленный позже, сейф не откроет.
            builder.setInvalidatedByBiometricEnrollment(true)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore")
        generator.init(builder.build())
        generator.generateKey()
    }

    private fun mac(call: MethodCall, result: MethodChannel.Result) {
        val alias = call.argument<String>("alias") ?: ""
        val message = call.argument<ByteArray>("message") ?: ByteArray(0)
        val reason = call.argument<String>("reason")
        val key: SecretKey
        val mac: Mac
        try {
            key = (keyStore().getKey(alias, null) as? SecretKey)
                ?: return fail(result, "KEY_LOST", message)
            mac = Mac.getInstance("HmacSHA256")
            mac.init(key)
        } catch (error: KeyPermanentlyInvalidatedException) {
            return fail(result, "KEY_INVALIDATED", message)
        } catch (error: UserNotAuthenticatedException) {
            return prompt(alias, message, reason, result)
        } catch (error: Exception) {
            return fail(result, "UNAVAILABLE", message)
        }
        if (!requiresAuth(key)) {
            background(result) {
                try {
                    mac.doFinal(message)
                } finally {
                    Arrays.fill(message, 0)
                }
            }
            return
        }
        authenticate(mac, message, reason, result)
    }

    private fun requiresAuth(key: SecretKey): Boolean = try {
        val factory = javax.crypto.SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
        val info = factory.getKeySpec(key, android.security.keystore.KeyInfo::class.java)
            as android.security.keystore.KeyInfo
        info.isUserAuthenticationRequired
    } catch (error: Exception) {
        false
    }

    /** Ключ требует проверки, а `init` уже сказал об этом исключением. */
    private fun prompt(alias: String, message: ByteArray, reason: String?, result: MethodChannel.Result) {
        try {
            val key = keyStore().getKey(alias, null) as? SecretKey
                ?: return fail(result, "KEY_LOST", message)
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(key)
            authenticate(mac, message, reason, result)
        } catch (error: KeyPermanentlyInvalidatedException) {
            fail(result, "KEY_INVALIDATED", message)
        } catch (error: Exception) {
            fail(result, "UNAVAILABLE", message)
        }
    }

    private fun authenticate(mac: Mac, message: ByteArray, reason: String?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return fail(result, "UNAVAILABLE", message)
        }
        val prompt = BiometricPrompt.Builder(activity)
            .setTitle(reason ?: "Сейф")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()
        var done = false
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                if (done) return
                done = true
                val ready = auth.cryptoObject?.mac
                if (ready == null) {
                    fail(result, "UNAVAILABLE", message)
                    return
                }
                try {
                    val out = ready.doFinal(message)
                    result.success(out)
                } catch (error: Exception) {
                    result.error("UNAVAILABLE", null, null)
                } finally {
                    Arrays.fill(message, 0)
                }
            }

            override fun onAuthenticationError(code: Int, text: CharSequence?) {
                if (done) return
                done = true
                val failure = when (code) {
                    BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
                    BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "AUTH_LOCKOUT"
                    BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS,
                    BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT,
                    BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE,
                    BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL -> "UNAVAILABLE"
                    else -> "AUTH_CANCELED"
                }
                fail(result, failure, message)
            }
        }
        main.post {
            try {
                prompt.authenticate(
                    BiometricPrompt.CryptoObject(mac),
                    CancellationSignal(),
                    activity.mainExecutor,
                    callback,
                )
            } catch (error: Exception) {
                if (!done) {
                    done = true
                    fail(result, "UNAVAILABLE", message)
                }
            }
        }
    }

    private fun fail(result: MethodChannel.Result, code: String, message: ByteArray) {
        Arrays.fill(message, 0)
        main.post { result.error(code, null, null) }
    }

    private fun background(result: MethodChannel.Result, action: () -> Any?) {
        Thread {
            val outcome: Result<Any?> = try {
                Result.success(action())
            } catch (error: Exception) {
                Result.failure(error)
            }
            main.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { error ->
                        val code = when (error) {
                            is VaultKeyFailure -> error.code
                            is KeyPermanentlyInvalidatedException -> "KEY_INVALIDATED"
                            else -> "UNAVAILABLE"
                        }
                        result.error(code, null, null)
                    },
                )
            }
        }.start()
    }
}

/** Отказ с кодом для Dart, без подробностей системы. */
class VaultKeyFailure(val code: String) : Exception(code)

/**
 * Вход в приложение по отпечатку / Face ID (ADR-025): системный запрос
 * биометрии с запасным PIN-кодом или паролем экрана. Это проверка в
 * интерфейсе, а не шифрование: данные приложения не меняются.
 */
class DeviceAuthChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "tridot/auth").setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "authenticate" -> authenticate(call.argument<String>("reason"), result)
            else -> result.notImplemented()
        }
    }

    private val allowed: Int
        get() = BiometricManager.Authenticators.BIOMETRIC_WEAK or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL

    private fun status(): Map<String, Any> {
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val credential = keyguard.isDeviceSecure
        val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
        var biometric = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = activity.getSystemService(BiometricManager::class.java)
            biometric = manager?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) ==
                BiometricManager.BIOMETRIC_SUCCESS
        }
        val kinds = mutableListOf<String>()
        val pm = activity.packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)) kinds.add("fingerprint")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            pm.hasSystemFeature(PackageManager.FEATURE_FACE)
        ) {
            kinds.add("face")
        }
        return mapOf(
            "supported" to supported,
            "credential" to credential,
            "biometric" to biometric,
            "kinds" to kinds,
        )
    }

    private fun authenticate(reason: String?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success("unavailable")
            return
        }
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isDeviceSecure) {
            result.success("unavailable")
            return
        }
        val prompt = BiometricPrompt.Builder(activity)
            .setTitle(reason ?: "Tridot")
            .setAllowedAuthenticators(allowed)
            .build()
        var done = false
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                if (done) return
                done = true
                result.success("ok")
            }

            override fun onAuthenticationError(code: Int, text: CharSequence?) {
                if (done) return
                done = true
                result.success(
                    when (code) {
                        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
                        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "lockout"
                        BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL,
                        BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "unavailable"
                        else -> "canceled"
                    },
                )
            }
        }
        main.post {
            try {
                prompt.authenticate(CancellationSignal(), activity.mainExecutor, callback)
            } catch (error: Exception) {
                if (!done) {
                    done = true
                    result.success("unavailable")
                }
            }
        }
    }
}
