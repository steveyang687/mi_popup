package com.mipopup.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer

class LanProtocolTest {
    @Test
    fun encodesDeliveryUpdateEnvelope() {
        val deviceId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        val encoded = LanProtocol.encodeDeliveryUpdate(
            deviceId = deviceId,
            sequence = 42,
            sentAt = 1234,
            deliveryUpdateJson = """{"eventId":"11111111-1111-4111-8111-111111111111","state":"delivering"}"""
        )

        assertEquals(
            """{"protocolVersion":1,"type":"delivery_update","deviceId":"$deviceId","sequence":42,"sentAt":1234,"payload":{"eventId":"11111111-1111-4111-8111-111111111111","state":"delivering"}}""",
            encoded
        )
    }

    @Test
    fun decodesAcceptedAndDuplicateAcknowledgements() {
        val accepted = LanProtocol.decodeAck(
            """{"status":"accepted","acceptedAt":2000,"eventId":"11111111-1111-4111-8111-111111111111","type":"ack","protocolVersion":1}"""
        )
        val duplicate = LanProtocol.decodeAck(
            """{"protocolVersion":1,"type":"ack","eventId":"22222222-2222-4222-8222-222222222222","status":"duplicate","acceptedAt":2001}"""
        )

        assertEquals(LanAck("11111111-1111-4111-8111-111111111111", "accepted", 2000), accepted)
        assertEquals(LanAck("22222222-2222-4222-8222-222222222222", "duplicate", 2001), duplicate)
    }

    @Test
    fun rejectsMalformedAcknowledgements() {
        assertNull(
            LanProtocol.decodeAck(
                """{"protocolVersion":2,"type":"ack","eventId":"11111111-1111-4111-8111-111111111111","status":"accepted","acceptedAt":1}"""
            )
        )
        assertNull(
            LanProtocol.decodeAck(
                """{"protocolVersion":1,"type":"ack","eventId":"11111111-1111-4111-8111-111111111111","status":"rejected","acceptedAt":1}"""
            )
        )
        assertNull(
            LanProtocol.decodeAck(
                """{"protocolVersion":1,"type":"ack","eventId":"../event","status":"accepted","acceptedAt":1}"""
            )
        )
        assertNull(
            LanProtocol.decodeAck(
                """{"protocolVersion":1,"type":"ack","eventId":"11111111-1111-4111-8111-111111111111","status":"accepted","acceptedAt":1,"unexpected":true}"""
            )
        )
        assertNull(
            LanProtocol.decodeAck(
                """{"protocolVersion":1,"protocolVersion":1,"type":"ack","eventId":"11111111-1111-4111-8111-111111111111","status":"accepted","acceptedAt":1}"""
            )
        )
    }

    @Test
    fun frameCodecUsesUtf8ByteLengthAndReadsFragmentedInput() {
        val payload = """{"status":"配送中"}"""
        val output = ByteArrayOutputStream()
        LanFrameCodec.write(output, payload)
        val bytes = output.toByteArray()

        assertEquals(payload.toByteArray(Charsets.UTF_8).size, ByteBuffer.wrap(bytes, 0, 4).int)
        val decoded = LanFrameCodec.read(OneByteAtATimeInputStream(bytes))
        assertEquals(payload, decoded)
    }

    @Test
    fun frameCodecRejectsInvalidLengths() {
        val tooLarge = "x".repeat(LanProtocol.MAX_FRAME_BYTES + 1)
        val writeError = runCatching {
            LanFrameCodec.write(ByteArrayOutputStream(), tooLarge)
        }.exceptionOrNull()
        assertNotNull(writeError)
        assertEquals(IOException::class.java, writeError?.javaClass)

        val invalidHeader = ByteBuffer.allocate(4)
            .putInt(LanProtocol.MAX_FRAME_BYTES + 1)
            .array()
        val readError = runCatching {
            LanFrameCodec.read(ByteArrayInputStream(invalidHeader))
        }.exceptionOrNull()
        assertNotNull(readError)
        assertEquals(IOException::class.java, readError?.javaClass)
    }

    private class OneByteAtATimeInputStream(
        private val bytes: ByteArray
    ) : InputStream() {
        private var index = 0

        override fun read(): Int =
            if (index >= bytes.size) -1 else bytes[index++].toInt() and 0xff

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (index >= bytes.size) return -1
            buffer[offset] = bytes[index++]
            return 1
        }
    }
}
