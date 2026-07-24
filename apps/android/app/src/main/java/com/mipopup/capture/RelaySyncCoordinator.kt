package com.mipopup.capture

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.PowerManager
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class RelaySyncCoordinator(
    context: Context,
    private val outbox: LanOutboxStore,
    private val configuration: RelayConfiguration
) {
    private val applicationContext = context.applicationContext
    private val scheduler = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "mipopup-relay-sync")
    }
    private val connectivityManager = applicationContext.getSystemService(ConnectivityManager::class.java)
    private val wakeLock = applicationContext.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "${applicationContext.packageName}:relay-sync")
        .apply { setReferenceCounted(false) }
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private var scheduledAttempt: ScheduledFuture<*>? = null
    private var attemptRunning = false
    private var rerunRequested = false
    private var failureCount = 0
    private var callbackRegistered = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = networkChanged()
        override fun onLost(network: Network) = networkChanged()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
            networkChanged()
    }

    fun start() {
        if (!started.compareAndSet(false, true) || closed.get()) return
        callbackRegistered = runCatching {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
            true
        }.getOrDefault(false)
        dispatch { scheduleAttempt(0, replaceExisting = false) }
    }

    fun kick() {
        acquireWakeLock()
        dispatch {
            failureCount = 0
            if (attemptRunning) rerunRequested = true else scheduleAttempt(0, replaceExisting = true)
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        scheduledAttempt?.cancel(false)
        if (callbackRegistered) {
            runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            callbackRegistered = false
        }
        releaseWakeLock()
        scheduler.shutdownNow()
        RelaySyncMonitor.update(
            RelaySyncPhase.STOPPED,
            safePendingCount(),
            "公网中继已停止"
        )
    }

    private fun networkChanged() {
        acquireWakeLock()
        dispatch {
            failureCount = 0
            if (attemptRunning) rerunRequested = true
            else scheduleAttempt(NETWORK_SETTLE_MILLIS, replaceExisting = true)
        }
    }

    private fun scheduleAttempt(delayMillis: Long, replaceExisting: Boolean) {
        if (closed.get()) return
        val pending = safePendingCount()
        if (pending == 0) {
            scheduledAttempt?.cancel(false)
            scheduledAttempt = null
            RelaySyncMonitor.update(RelaySyncPhase.IDLE, 0, "公网中继已同步")
            releaseWakeLock()
            return
        }
        if (attemptRunning) {
            rerunRequested = true
            return
        }
        scheduledAttempt?.let { existing ->
            if (!existing.isDone) {
                if (!replaceExisting) return
                existing.cancel(false)
            }
        }
        scheduledAttempt = scheduler.schedule(
            {
                scheduledAttempt = null
                attempt()
            },
            delayMillis,
            TimeUnit.MILLISECONDS
        )
        if (delayMillis > 0) {
            RelaySyncMonitor.update(
                RelaySyncPhase.WAITING_RETRY,
                pending,
                "等待公网中继重试"
            )
        }
    }

    private fun attempt() {
        if (closed.get() || attemptRunning) return
        acquireWakeLock()
        val entries = runCatching { outbox.peek(RELAY_BATCH_SIZE) }
            .getOrElse { return failAttempt("无法读取中继队列：${shortError(it)}") }
        if (entries.isEmpty()) {
            RelaySyncMonitor.update(RelaySyncPhase.IDLE, 0, "公网中继已同步")
            releaseWakeLock()
            return
        }
        if (!hasInternet()) {
            RelaySyncMonitor.update(
                RelaySyncPhase.IDLE,
                safePendingCount(),
                "等待可用网络后同步"
            )
            releaseWakeLock()
            return
        }

        attemptRunning = true
        RelaySyncMonitor.update(
            RelaySyncPhase.SENDING,
            safePendingCount(),
            "正在向加密中继发送配送状态"
        )
        var acknowledgedAt: Long? = null
        try {
            entries.forEach { entry ->
                val event = RelayProtocol.encrypt(entry, configuration)
                RelayHttpClient.post(configuration, event)
                check(outbox.acknowledge(entry.eventId)) { "中继确认后无法删除本地事件" }
                acknowledgedAt = System.currentTimeMillis()
            }
        } catch (error: Throwable) {
            failAttempt("公网中继发送失败：${shortError(error)}")
            return
        }

        attemptRunning = false
        failureCount = 0
        releaseWakeLock()
        val pending = safePendingCount()
        RelaySyncMonitor.update(
            if (pending == 0) RelaySyncPhase.IDLE else RelaySyncPhase.SENDING,
            pending,
            if (pending == 0) "公网中继已同步" else "继续发送待同步状态",
            acknowledgedAt
        )
        if (rerunRequested || pending > 0) {
            rerunRequested = false
            scheduleAttempt(0, replaceExisting = true)
        }
    }

    private fun failAttempt(message: String) {
        attemptRunning = false
        releaseWakeLock()
        failureCount += 1
        val retryDelay = LanRetryPolicy.delayAfterFailure(failureCount - 1)
        if (retryDelay == null) {
            RelaySyncMonitor.update(
                RelaySyncPhase.IDLE,
                safePendingCount(),
                "$message；等待新事件或网络变化"
            )
        } else {
            scheduleAttempt(retryDelay, replaceExisting = true)
            RelaySyncMonitor.update(
                RelaySyncPhase.WAITING_RETRY,
                safePendingCount(),
                "$message；稍后自动重试"
            )
        }
    }

    private fun hasInternet(): Boolean = runCatching {
        val network = connectivityManager.activeNetwork ?: return@runCatching false
        connectivityManager.getNetworkCapabilities(network)
            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }.getOrDefault(false)

    private fun safePendingCount(): Int = runCatching { outbox.pendingCount() }.getOrDefault(0)

    private fun acquireWakeLock() {
        runCatching { wakeLock.acquire(WAKE_LOCK_TIMEOUT_MILLIS) }
    }

    private fun releaseWakeLock() {
        runCatching { if (wakeLock.isHeld) wakeLock.release() }
    }

    private fun dispatch(action: () -> Unit) {
        if (closed.get()) return
        try {
            scheduler.execute { if (!closed.get()) action() }
        } catch (_: RejectedExecutionException) {
            // A late framework callback raced with Service destruction.
        }
    }

    companion object {
        private const val NETWORK_SETTLE_MILLIS = 300L
        private const val WAKE_LOCK_TIMEOUT_MILLIS = 35_000L
        private const val RELAY_BATCH_SIZE = 2

        private fun shortError(error: Throwable): String =
            error.localizedMessage?.take(160) ?: error.javaClass.simpleName
    }
}

private object RelayHttpClient {
    fun post(configuration: RelayConfiguration, event: RelayWireEvent) {
        val payload = event.toJson().toByteArray(Charsets.UTF_8)
        val connection = URL("${configuration.baseURL}/v1/events")
            .openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 7_000
            connection.readTimeout = 8_000
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(payload.size)
            connection.setRequestProperty("Authorization", "Bearer ${configuration.token}")
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.outputStream.use { it.write(payload) }
            val status = connection.responseCode
            val responseBytes = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.use { it.readAtMost(MAX_RESPONSE_BYTES + 1) }
                ?: ByteArray(0)
            if (responseBytes.size > MAX_RESPONSE_BYTES) throw IOException("中继响应过大")
            if (status !in 200..299) throw IOException("中继返回 HTTP $status")
            val response = JSONObject(responseBytes.toString(Charsets.UTF_8))
            val responseEventId = response.optString("eventId")
            val responseStatus = response.optString("status")
            if (responseEventId != event.eventId || responseStatus !in setOf("accepted", "duplicate")) {
                throw IOException("中继返回无效确认")
            }
        } finally {
            connection.disconnect()
        }
    }

    private const val MAX_RESPONSE_BYTES = 4 * 1024

    private fun InputStream.readAtMost(limit: Int): ByteArray {
        val output = ByteArrayOutputStream(limit)
        val buffer = ByteArray(1024)
        while (output.size() < limit) {
            val count = read(buffer, 0, minOf(buffer.size, limit - output.size()))
            if (count < 0) break
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}
