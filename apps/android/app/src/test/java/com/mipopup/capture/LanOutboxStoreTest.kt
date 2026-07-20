package com.mipopup.capture

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class LanOutboxStoreTest {
    private val directory = Files.createTempDirectory("mipopup-outbox-test").toFile()
    private val event1 = "11111111-1111-4111-8111-111111111111"
    private val event2 = "22222222-2222-4222-8222-222222222222"
    private val event3 = "33333333-3333-4333-8333-333333333333"

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    @Test
    fun persistsEntriesAcrossStoreInstancesAndAcknowledgesByEventId() {
        val first = LanOutboxStore(directory)
        assertTrue(first.enqueue(entry(sequence = 1, eventId = event1)))
        assertTrue(first.enqueue(entry(sequence = 2, eventId = event2)))

        val reopened = LanOutboxStore(directory)
        assertEquals(listOf(event1, event2), reopened.peek().map { it.eventId })
        assertTrue(reopened.acknowledge(event1))
        assertFalse(reopened.acknowledge(event1))
        assertEquals(listOf(event2), reopened.peek().map { it.eventId })
    }

    @Test
    fun ordersBySequenceAndKeepsOnlyCapacity() {
        val store = LanOutboxStore(
            directory = directory,
            maxEntries = 2
        )
        store.enqueue(entry(sequence = 2, eventId = event2))
        store.enqueue(entry(sequence = 1, eventId = event1))
        store.enqueue(entry(sequence = 3, eventId = event3))

        assertEquals(listOf(2L, 3L), store.peek().map { it.sequence })
    }

    @Test
    fun expiresOldEntriesAndRemovesInterruptedTemporaryFiles() {
        var now = 1_000L
        val store = LanOutboxStore(
            directory = directory,
            nowMillis = { now },
            retentionMillis = 100L
        )
        store.enqueue(entry(sequence = 1, eventId = event1))
        val temporary = directory.resolve(".interrupted.tmp")
        temporary.writeText("partial")

        now = 1_101L

        assertEquals(0, store.pendingCount())
        assertFalse(temporary.exists())
    }

    @Test
    fun duplicateEnqueueIsIdempotent() {
        val store = LanOutboxStore(directory)
        val original = entry(sequence = 1, eventId = event1)
        val changed = entry(sequence = 2, eventId = event1)

        assertTrue(store.enqueue(original))
        assertTrue(store.enqueue(changed))

        assertEquals(original.envelopeJson, store.peek().single().envelopeJson)
    }

    private fun entry(sequence: Long, eventId: String): LanOutboxEntry {
        val envelope = LanProtocol.encodeDeliveryUpdate(
            deviceId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sequence = sequence,
            sentAt = 1_000L + sequence,
            deliveryUpdateJson = """{"eventId":"$eventId","state":"unknown"}"""
        )
        return LanOutboxEntry(eventId, sequence, envelope)
    }
}
