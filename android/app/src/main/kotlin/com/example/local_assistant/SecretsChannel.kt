package com.example.local_assistant

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.Arrays
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Секреты подключений (ADR-031): AES-256-GCM ключом `tridot-secrets` в
 * Android Keystore (StrongBox, если есть, иначе TEE). Ключ не покидает
 * защищённое железо; наружу уходит только шифротекст `iv(12) + ct`.
 * Без проверки личности: ключи склада нужны помощнику и без разблокировки
 * сейфа. Входные байты затираются.
 */
class SecretsChannel(messenger: BinaryMessenger) {
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "tridot/secrets").setMethodCallHandler { call, result ->
            val data = call.argument<ByteArray>("data")
            when (call.method) {
                "seal" -> background(result) { seal(data ?: ByteArray(0)) }
                "open" -> background(result) { open(data ?: ByteArray(0)) }
                else -> result.notImplemented()
            }
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> ByteArray) {
        Thread {
            try {
                val out = work()
                main.post { result.success(out) }
            } catch (error: Exception) {
                main.post { result.error("secrets", error.javaClass.simpleName, null) }
            }
        }.start()
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return try {
            generate(strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        } catch (error: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                error is StrongBoxUnavailableException
            ) {
                generate(strongBox = false)
            } else {
                throw error
            }
        }
    }

    private fun generate(strongBox: Boolean): SecretKey {
        val builder = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun seal(plain: ByteArray): ByteArray {
        try {
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val iv = cipher.iv
            require(iv.size == IV) { "iv" }
            return iv + cipher.doFinal(plain)
        } finally {
            Arrays.fill(plain, 0)
        }
    }

    private fun open(sealed: ByteArray): ByteArray {
        require(sealed.size > IV + 16) { "short" }
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(),
            GCMParameterSpec(128, sealed, 0, IV),
        )
        return cipher.doFinal(sealed, IV, sealed.size - IV)
    }

    companion object {
        private const val ALIAS = "tridot-secrets"
        private const val TRANSFORM = "AES/GCM/NoPadding"
        private const val IV = 12
    }
}
