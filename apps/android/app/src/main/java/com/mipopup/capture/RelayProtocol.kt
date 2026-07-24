package com.mipopup.capture

import org.json.JSONObject
import java.net.URI
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class RelayConfiguration(
    val baseURL: String,
    val channelId: String,
    val token: String,
    val encryptionKey: ByteArray
) {
    override fun equals(other: Any?): Boolean =
        other is RelayConfiguration &&
            baseURL == other.baseURL &&
            channelId == other.channelId &&
            token == other.token &&
            encryptionKey.contentEquals(other.encryptionKey)

    override fun hashCode(): Int =
        31 * (31 * (31 * baseURL.hashCode() + channelId.hashCode()) + token.hashCode()) +
            encryptionKey.contentHashCode()
}

data class RelayWireEvent(
    val version: Int,
    val channelId: String,
    val eventId: String,
    val sequence: Long,
    val sentAt: Long,
    val nonce: String,
    val ciphertext: String
) {
    fun toJson(): String = JSONObject()
        .put("version", version)
        .put("channelId", channelId)
        .put("eventId", eventId)
        .put("sequence", sequence)
        .put("sentAt", sentAt)
        .put("nonce", nonce)
        .put("ciphertext", ciphertext)
        .toString()
}

object RelayProtocol {
    const val VERSION = 1
    const val OUTBOX_DIRECTORY_NAME = "relay-delivery-outbox"
    private const val GCM_TAG_BITS = 128
    private const val NONCE_BYTES = 12
    private val channelPattern = Regex("[A-Za-z0-9_-]{8,64}")

    fun parseConfiguration(json: String): RelayConfiguration {
        val root = JSONObject(json)
        val keys = root.keys().asSequence().toSet()
        require(keys == setOf("baseURL", "channelId", "token", "encryptionKey")) {
            "配置字段必须为 baseURL、channelId、token、encryptionKey"
        }
        val rawBaseURL = root.getString("baseURL").trim().trimEnd('/')
        val uri = URI(rawBaseURL)
        require(uri.scheme.equals("https", ignoreCase = true)) { "baseURL 必须使用 https" }
        require(
            !uri.host.isNullOrBlank() &&
                uri.userInfo == null &&
                uri.query == null &&
                uri.fragment == null &&
                (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")
        ) {
            "baseURL 格式无效"
        }
        val channelId = root.getString("channelId")
        require(channelPattern.matches(channelId)) { "channelId 格式无效" }
        val token = root.getString("token")
        require(token.length in 32..256 && token.none(Char::isWhitespace)) { "token 格式无效" }
        val encodedKey = root.getString("encryptionKey")
        val key = runCatching { Base64.getDecoder().decode(encodedKey) }
            .getOrElse { throw IllegalArgumentException("encryptionKey 不是 Base64", it) }
        require(key.size == 32 && Base64.getEncoder().encodeToString(key) == encodedKey) {
            "encryptionKey 必须是 32 字节标准 Base64"
        }
        return RelayConfiguration(rawBaseURL, channelId, token, key)
    }

    fun encodeConfiguration(configuration: RelayConfiguration): String = JSONObject()
        .put("baseURL", configuration.baseURL)
        .put("channelId", configuration.channelId)
        .put("token", configuration.token)
        .put("encryptionKey", Base64.getEncoder().encodeToString(configuration.encryptionKey))
        .toString(2)

    fun encrypt(
        entry: LanOutboxEntry,
        configuration: RelayConfiguration,
        sentAt: Long = System.currentTimeMillis(),
        nonce: ByteArray = ByteArray(NONCE_BYTES).also(SecureRandom()::nextBytes)
    ): RelayWireEvent {
        require(nonce.size == NONCE_BYTES) { "Relay nonce must be 12 bytes" }
        require(sentAt >= 0) { "sentAt must not be negative" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(configuration.encryptionKey, "AES"),
            GCMParameterSpec(GCM_TAG_BITS, nonce)
        )
        cipher.updateAAD(authenticatedData(
            configuration.channelId,
            entry.eventId,
            entry.sequence,
            sentAt
        ))
        val ciphertext = cipher.doFinal(entry.envelopeJson.toByteArray(Charsets.UTF_8))
        return RelayWireEvent(
            version = VERSION,
            channelId = configuration.channelId,
            eventId = entry.eventId,
            sequence = entry.sequence,
            sentAt = sentAt,
            nonce = Base64.getEncoder().encodeToString(nonce),
            ciphertext = Base64.getEncoder().encodeToString(ciphertext)
        )
    }

    fun authenticatedData(
        channelId: String,
        eventId: String,
        sequence: Long,
        sentAt: Long
    ): ByteArray = "mipopup-relay-v1\n$channelId\n$eventId\n$sequence\n$sentAt"
        .toByteArray(Charsets.UTF_8)
}
