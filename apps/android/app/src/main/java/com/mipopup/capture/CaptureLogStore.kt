package com.mipopup.capture

import android.content.Context
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

data class CaptureSnapshot(
    val eventCount: Int,
    val fileCount: Int,
    val totalBytes: Long
)

class CaptureLogStore(context: Context) {
    private val directory = File(context.applicationContext.filesDir, DIRECTORY_NAME)

    @Synchronized
    fun append(record: JSONObject) {
        directory.mkdirs()
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val target = File(directory, "events-$day.jsonl")
        target.appendText(record.toString() + "\n", Charsets.UTF_8)
        prune()
    }

    @Synchronized
    fun snapshot(): CaptureSnapshot {
        val files = logFiles()
        var events = 0
        files.forEach { file ->
            file.bufferedReader().useLines { lines -> events += lines.count() }
        }
        return CaptureSnapshot(events, files.size, files.sumOf(File::length))
    }

    @Synchronized
    fun recentRedacted(limit: Int): List<String> {
        val recent = ArrayDeque<String>(limit)
        logFiles().forEach { file ->
            file.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    val rendered = runCatching {
                        val json = Redactor.redact(JSONObject(line))
                        "${json.optString("eventKind")} · ${json.optString("appName")}\n" +
                            listOf(json.optString("title"), json.optString("text"))
                                .filter(String::isNotBlank)
                                .joinToString(" — ")
                    }.getOrDefault("无法读取的日志行")
                    if (recent.size == limit) recent.removeFirst()
                    recent.addLast(rendered)
                }
            }
        }
        return recent.toList().asReversed()
    }

    @Synchronized
    fun exportRedacted(outputStream: OutputStream): Int {
        var count = 0
        BufferedWriter(OutputStreamWriter(outputStream, Charsets.UTF_8)).use { writer ->
            logFiles().forEach { file ->
                file.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        val redacted = Redactor.redact(JSONObject(line))
                        writer.write(redacted.toString())
                        writer.newLine()
                        count += 1
                    }
                }
            }
        }
        return count
    }

    @Synchronized
    fun clear() {
        logFiles().forEach(File::delete)
    }

    private fun logFiles(): List<File> = directory
        .listFiles { file -> file.isFile && file.name.endsWith(".jsonl") }
        ?.sortedBy { it.name }
        .orEmpty()

    private fun prune() {
        val cutoff = System.currentTimeMillis() - RETENTION_MILLIS
        logFiles().filter { it.lastModified() < cutoff }.forEach(File::delete)

        val remaining = logFiles().toMutableList()
        var total = remaining.sumOf(File::length)
        while (total > MAX_BYTES && remaining.size > 1) {
            val oldest = remaining.removeAt(0)
            total -= oldest.length()
            oldest.delete()
        }
    }

    companion object {
        private const val DIRECTORY_NAME = "notification-capture"
        private const val MAX_BYTES = 20L * 1024L * 1024L
        private const val RETENTION_MILLIS = 7L * 24L * 60L * 60L * 1000L
    }
}
