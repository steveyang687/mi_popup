package com.mipopup.capture

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

data class LanAck(
    val eventId: String,
    val status: String,
    val acceptedAt: Long
)

object LanProtocol {
    const val PROTOCOL_VERSION = 1
    const val MAX_FRAME_BYTES = 16 * 1024

    private val identifierPattern = Regex(
        """[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"""
    )

    fun encodeDeliveryUpdate(
        deviceId: String,
        sequence: Long,
        sentAt: Long,
        deliveryUpdateJson: String
    ): String {
        require(identifierPattern.matches(deviceId)) { "Invalid deviceId" }
        require(sequence > 0) { "sequence must be positive" }
        require(sentAt >= 0) { "sentAt must not be negative" }
        val payload = deliveryUpdateJson.trim()
        require(payload.startsWith('{') && payload.endsWith('}')) {
            "Delivery update payload must be a JSON object"
        }
        return buildString(payload.length + 160) {
            append("{\"protocolVersion\":")
            append(PROTOCOL_VERSION)
            append(",\"type\":\"delivery_update\",\"deviceId\":\"")
            append(deviceId)
            append("\",\"sequence\":")
            append(sequence)
            append(",\"sentAt\":")
            append(sentAt)
            append(",\"payload\":")
            append(payload)
            append('}')
        }.also { envelope ->
            require(envelope.toByteArray(Charsets.UTF_8).size <= MAX_FRAME_BYTES) {
                "Delivery update frame exceeds $MAX_FRAME_BYTES bytes"
            }
        }
    }

    fun decodeAck(json: String): LanAck? {
        val value = json.trim()
        if (!value.startsWith('{') || !value.endsWith('}')) return null
        val keys = fieldNamePattern.findAll(value).map { it.groupValues[1] }.toList()
        if (keys.size != ACK_FIELDS.size || keys.toSet() != ACK_FIELDS) return null
        if (longField(value, "protocolVersion") != PROTOCOL_VERSION.toLong()) return null
        if (stringField(value, "type") != "ack") return null
        val eventId = stringField(value, "eventId")
            ?.takeIf(identifierPattern::matches)
            ?: return null
        val status = stringField(value, "status")
            ?.takeIf { it == "accepted" || it == "duplicate" }
            ?: return null
        val acceptedAt = longField(value, "acceptedAt")
            ?.takeIf { it >= 0 }
            ?: return null
        return LanAck(eventId, status, acceptedAt)
    }

    fun isValidIdentifier(value: String): Boolean = identifierPattern.matches(value)

    private fun stringField(json: String, name: String): String? {
        val escapedName = Regex.escape(name)
        return Regex("\"$escapedName\"\\s*:\\s*\"([A-Za-z0-9._:-]{1,128})\"")
            .find(json)
            ?.groupValues
            ?.get(1)
    }

    private fun longField(json: String, name: String): Long? {
        val escapedName = Regex.escape(name)
        return Regex("\"$escapedName\"\\s*:\\s*(-?\\d+)")
            .find(json)
            ?.groupValues
            ?.get(1)
            ?.toLongOrNull()
    }

    private val fieldNamePattern = Regex("\"([A-Za-z][A-Za-z0-9]*)\"\\s*:")
    private val ACK_FIELDS = setOf(
        "protocolVersion",
        "type",
        "eventId",
        "status",
        "acceptedAt"
    )
}

object LanFrameCodec {
    fun write(output: OutputStream, payload: String) {
        val bytes = payload.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > LanProtocol.MAX_FRAME_BYTES) {
            throw IOException("Invalid LAN frame length: ${bytes.size}")
        }
        DataOutputStream(output).apply {
            writeInt(bytes.size)
            write(bytes)
            flush()
        }
    }

    fun read(input: InputStream): String {
        val stream = DataInputStream(input)
        val length = stream.readInt()
        if (length <= 0 || length > LanProtocol.MAX_FRAME_BYTES) {
            throw IOException("Invalid LAN frame length: $length")
        }
        val bytes = ByteArray(length)
        stream.readFully(bytes)
        return bytes.toString(Charsets.UTF_8)
    }
}
