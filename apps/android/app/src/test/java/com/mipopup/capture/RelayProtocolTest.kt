package com.mipopup.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class RelayProtocolTest {
    @Test
    fun parsesSharedConfigurationAndRejectsInsecureURL() {
        val key = ByteArray(32) { it.toByte() }
        val json = """
            {
              "baseURL": "https://relay.example.com/",
              "channelId": "personal_channel_01",
              "token": "token-that-is-longer-than-thirty-two-characters",
              "encryptionKey": "${Base64.getEncoder().encodeToString(key)}"
            }
        """.trimIndent()

        val configuration = RelayProtocol.parseConfiguration(json)
        assertEquals("https://relay.example.com", configuration.baseURL)
        assertTrue(configuration.encryptionKey.contentEquals(key))

        val insecure = json.replace("https://", "http://")
        assertTrue(runCatching { RelayProtocol.parseConfiguration(insecure) }.isFailure)
    }

    @Test
    fun encryptsEnvelopeWithMetadataAsAuthenticatedData() {
        val key = ByteArray(32) { (it + 1).toByte() }
        val configuration = RelayConfiguration(
            baseURL = "https://relay.example.com",
            channelId = "personal_channel_01",
            token = "token-that-is-longer-than-thirty-two-characters",
            encryptionKey = key
        )
        val entry = LanOutboxEntry(
            eventId = "11111111-1111-4111-8111-111111111111",
            sequence = 7,
            envelopeJson = "{\"protocolVersion\":1}"
        )
        val event = RelayProtocol.encrypt(
            entry,
            configuration,
            sentAt = 42,
            nonce = ByteArray(12) { 3 }
        )

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(128, Base64.getDecoder().decode(event.nonce))
        )
        cipher.updateAAD(RelayProtocol.authenticatedData(
            event.channelId,
            event.eventId,
            event.sequence,
            event.sentAt
        ))
        val plaintext = cipher.doFinal(Base64.getDecoder().decode(event.ciphertext))

        assertEquals(entry.envelopeJson, plaintext.toString(Charsets.UTF_8))
    }
}
