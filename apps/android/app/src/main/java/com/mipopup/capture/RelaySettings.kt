package com.mipopup.capture

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class RelaySettings(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE
    )

    fun load(): RelayConfiguration? = synchronized(settingsLock) {
        val nonce = preferences.getString(KEY_NONCE, null) ?: return null
        val ciphertext = preferences.getString(KEY_CIPHERTEXT, null) ?: return null
        runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(128, Base64.getDecoder().decode(nonce))
            )
            val plaintext = cipher.doFinal(Base64.getDecoder().decode(ciphertext))
            RelayProtocol.parseConfiguration(plaintext.toString(Charsets.UTF_8))
        }.getOrNull()
    }

    fun save(configuration: RelayConfiguration) = synchronized(settingsLock) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val plaintext = RelayProtocol.encodeConfiguration(configuration).toByteArray(Charsets.UTF_8)
        val ciphertext = cipher.doFinal(plaintext)
        check(preferences.edit()
            .putString(KEY_NONCE, Base64.getEncoder().encodeToString(cipher.iv))
            .putString(KEY_CIPHERTEXT, Base64.getEncoder().encodeToString(ciphertext))
            .commit()) { "无法保存中继配置" }
    }

    fun clear() = synchronized(settingsLock) {
        check(preferences.edit().clear().commit()) { "无法删除中继配置" }
        runCatching {
            val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
            keyStore.deleteEntry(KEY_ALIAS)
        }
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    companion object {
        private const val PREFERENCES_NAME = "relay_settings"
        private const val KEY_NONCE = "configuration_nonce"
        private const val KEY_CIPHERTEXT = "configuration_ciphertext"
        private const val ANDROID_KEY_STORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "com.mipopup.capture.relay-config-v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private val settingsLock = Any()
    }
}
