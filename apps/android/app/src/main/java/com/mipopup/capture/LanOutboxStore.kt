package com.mipopup.capture

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

data class LanOutboxEntry(
    val eventId: String,
    val sequence: Long,
    val envelopeJson: String
)

class LanOutboxStore(
    private val directory: File,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
    private val retentionMillis: Long = DEFAULT_RETENTION_MILLIS
) {
    init {
        require(maxEntries > 0) { "maxEntries must be positive" }
        require(retentionMillis > 0) { "retentionMillis must be positive" }
    }

    fun enqueue(entry: LanOutboxEntry): Boolean {
        require(entry.sequence > 0) { "sequence must be positive" }
        require(LanProtocol.isValidIdentifier(entry.eventId)) { "Invalid eventId" }
        val bytes = entry.envelopeJson.toByteArray(Charsets.UTF_8)
        require(bytes.isNotEmpty() && bytes.size <= LanProtocol.MAX_FRAME_BYTES) {
            "Invalid outbox payload size: ${bytes.size}"
        }

        synchronized(globalLock) {
            ensureDirectory()
            pruneLocked()
            val suffix = "-${entry.eventId}$EVENT_SUFFIX"
            if (eventFilesLocked().any { it.name.endsWith(suffix) }) return true
            val target = File(directory, fileName(entry.sequence, entry.eventId))

            val temporary = File(directory, ".${target.name}.${UUID.randomUUID()}.tmp")
            try {
                FileOutputStream(temporary).use { output ->
                    output.write(bytes)
                    output.fd.sync()
                }
                if (!temporary.renameTo(target)) {
                    throw IOException("Unable to atomically persist LAN outbox event")
                }
                target.setLastModified(nowMillis())
                pruneLocked()
                return target.exists()
            } finally {
                temporary.delete()
            }
        }
    }

    fun peek(limit: Int = DEFAULT_BATCH_SIZE): List<LanOutboxEntry> {
        require(limit > 0) { "limit must be positive" }
        synchronized(globalLock) {
            pruneLocked()
            return eventFilesLocked()
                .take(limit)
                .mapNotNull { file ->
                    val match = filePattern.matchEntire(file.name) ?: return@mapNotNull null
                    val sequence = match.groupValues[1].toLongOrNull() ?: return@mapNotNull null
                    val eventId = match.groupValues[2]
                    val envelope = runCatching { file.readText(Charsets.UTF_8) }
                        .getOrElse {
                            file.delete()
                            return@mapNotNull null
                        }
                    val size = envelope.toByteArray(Charsets.UTF_8).size
                    if (size <= 0 || size > LanProtocol.MAX_FRAME_BYTES) {
                        file.delete()
                        return@mapNotNull null
                    }
                    LanOutboxEntry(eventId, sequence, envelope)
                }
        }
    }

    fun acknowledge(eventId: String): Boolean {
        if (!LanProtocol.isValidIdentifier(eventId)) return false
        synchronized(globalLock) {
            val suffix = "-$eventId$EVENT_SUFFIX"
            val targets = eventFilesLocked().filter { it.name.endsWith(suffix) }
            return targets.fold(false) { deletedAny, target ->
                target.delete() || deletedAny
            }
        }
    }

    fun pendingCount(): Int = synchronized(globalLock) {
        pruneLocked()
        eventFilesLocked().size
    }

    private fun ensureDirectory() {
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Unable to create LAN outbox directory")
        }
        if (!directory.isDirectory) throw IOException("LAN outbox path is not a directory")
    }

    private fun pruneLocked() {
        if (!directory.exists()) return
        directory.listFiles { file -> file.isFile && file.name.endsWith(".tmp") }
            ?.forEach(File::delete)

        val now = nowMillis()
        eventFilesLocked()
            .filter { file -> now >= file.lastModified() && now - file.lastModified() > retentionMillis }
            .forEach(File::delete)

        val remaining = eventFilesLocked().toMutableList()
        while (remaining.size > maxEntries) {
            remaining.removeAt(0).delete()
        }
    }

    private fun eventFilesLocked(): List<File> = directory
        .listFiles { file -> file.isFile && filePattern.matches(file.name) }
        ?.sortedBy(File::getName)
        .orEmpty()

    private fun fileName(sequence: Long, eventId: String): String =
        sequence.toString().padStart(SEQUENCE_WIDTH, '0') + "-$eventId$EVENT_SUFFIX"

    companion object {
        const val DIRECTORY_NAME = "lan-delivery-outbox"
        const val DEFAULT_MAX_ENTRIES = 200
        const val DEFAULT_BATCH_SIZE = 20
        const val DEFAULT_RETENTION_MILLIS = 24L * 60L * 60L * 1000L

        private const val SEQUENCE_WIDTH = 19
        private const val EVENT_SUFFIX = ".event"
        private val filePattern =
            Regex(
                """(\d{19})-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.event"""
            )
        private val globalLock = Any()
    }
}
