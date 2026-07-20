package com.mipopup.capture

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

data class LanEndpoint(
    val addresses: List<InetAddress>,
    val port: Int,
    val network: Network?
)

private data class LanSendResult(
    val acknowledgements: List<LanAck>,
    val errorMessage: String?
)

class LanSyncCoordinator(
    context: Context,
    private val outbox: LanOutboxStore
) {
    private val applicationContext = context.applicationContext
    private val scheduler = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "mipopup-lan-sync")
    }
    private val connectivityManager =
        applicationContext.getSystemService(ConnectivityManager::class.java)
    private val tcpClient = LanTcpClient()
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    @Volatile
    private var activeDiscovery: AndroidNsdDiscovery? = null

    @Volatile
    private var scheduledAttempt: ScheduledFuture<*>? = null

    private var cachedEndpoint: LanEndpoint? = null
    private var attemptRunning = false
    private var rerunRequested = false
    private var failureCount = 0
    private var networkCallbackRegistered = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            networkChanged()
        }

        override fun onLost(network: Network) {
            tcpClient.cancelActive()
            networkChanged()
        }

    }

    fun start() {
        if (!started.compareAndSet(false, true) || closed.get()) return
        networkCallbackRegistered = runCatching {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
            true
        }.getOrDefault(false)
        dispatch {
            LanSyncMonitor.update(
                phase = LanSyncPhase.IDLE,
                pendingCount = safePendingCount(),
                message = "等待配送状态"
            )
            scheduleAttempt(delayMillis = 0L, replaceExisting = false)
        }
    }

    fun kick() {
        dispatch {
            failureCount = 0
            if (attemptRunning) {
                rerunRequested = true
            } else {
                scheduleAttempt(delayMillis = 0L, replaceExisting = true)
            }
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        scheduledAttempt?.cancel(false)
        activeDiscovery?.cancel()
        tcpClient.shutdown()
        if (networkCallbackRegistered) {
            runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            networkCallbackRegistered = false
        }
        scheduler.shutdownNow()
        LanSyncMonitor.update(
            phase = LanSyncPhase.STOPPED,
            pendingCount = safePendingCount(),
            message = "局域网同步已停止"
        )
    }

    private fun networkChanged() {
        dispatch {
            cachedEndpoint = null
            failureCount = 0
            if (attemptRunning) {
                rerunRequested = true
            } else {
                scheduleAttempt(
                    delayMillis = NETWORK_SETTLE_MILLIS,
                    replaceExisting = true
                )
            }
        }
    }

    private fun scheduleAttempt(delayMillis: Long, replaceExisting: Boolean) {
        if (closed.get()) return
        val pending = safePendingCount()
        if (pending == 0) {
            scheduledAttempt?.cancel(false)
            scheduledAttempt = null
            LanSyncMonitor.update(
                phase = LanSyncPhase.IDLE,
                pendingCount = 0,
                message = "已同步，等待配送状态"
            )
            return
        }
        if (attemptRunning) {
            rerunRequested = true
            return
        }

        val existing = scheduledAttempt
        if (existing != null && !existing.isDone) {
            if (!replaceExisting) return
            existing.cancel(false)
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
            LanSyncMonitor.update(
                phase = LanSyncPhase.WAITING_RETRY,
                pendingCount = pending,
                message = "等待局域网重试"
            )
        }
    }

    private fun attempt() {
        if (closed.get() || attemptRunning) return
        val entries = runCatching { outbox.peek(LanOutboxStore.DEFAULT_BATCH_SIZE) }
            .getOrElse { error ->
                LanSyncMonitor.update(
                    phase = LanSyncPhase.IDLE,
                    pendingCount = safePendingCount(),
                    message = "无法读取待同步队列：${shortError(error)}"
                )
                return
            }
        if (entries.isEmpty()) {
            LanSyncMonitor.update(
                phase = LanSyncPhase.IDLE,
                pendingCount = 0,
                message = "已同步，等待配送状态"
            )
            return
        }
        if (!hasLanNetwork()) {
            LanSyncMonitor.update(
                phase = LanSyncPhase.IDLE,
                pendingCount = safePendingCount(),
                message = "待连接 Wi-Fi 后同步"
            )
            return
        }

        attemptRunning = true
        val endpoint = cachedEndpoint
        if (endpoint != null) {
            send(endpoint, entries)
            return
        }

        LanSyncMonitor.update(
            phase = LanSyncPhase.DISCOVERING,
            pendingCount = safePendingCount(),
            message = "正在发现同一局域网内的 Mac"
        )
        val discovery = AndroidNsdDiscovery(applicationContext, scheduler)
        activeDiscovery = discovery
        discovery.start { result ->
            dispatch {
                if (activeDiscovery === discovery) activeDiscovery = null
                result.fold(
                    onSuccess = { resolved ->
                        cachedEndpoint = resolved
                        send(resolved, entries)
                    },
                    onFailure = { error ->
                        failAttempt("未发现 Mac：${shortError(error)}")
                    }
                )
            }
        }
    }

    private fun send(endpoint: LanEndpoint, entries: List<LanOutboxEntry>) {
        LanSyncMonitor.update(
            phase = LanSyncPhase.SENDING,
            pendingCount = safePendingCount(),
            message = "正在向 Mac 发送配送状态"
        )
        val result = tcpClient.send(endpoint, entries)
        result.acknowledgements.forEach { acknowledgement ->
            outbox.acknowledge(acknowledgement.eventId)
        }
        val pending = safePendingCount()
        val latestAcknowledgement = result.acknowledgements.lastOrNull()
        if (latestAcknowledgement != null) {
            LanSyncMonitor.update(
                phase = LanSyncPhase.SENDING,
                pendingCount = pending,
                message = "Mac 已确认 ${result.acknowledgements.size} 条状态",
                acknowledgedAt = latestAcknowledgement.acceptedAt
            )
        }

        if (result.errorMessage != null) {
            cachedEndpoint = null
            failAttempt("局域网发送失败：${result.errorMessage}")
            return
        }

        attemptRunning = false
        failureCount = 0
        if (rerunRequested || pending > 0) {
            rerunRequested = false
            scheduleAttempt(delayMillis = 0L, replaceExisting = true)
        } else {
            LanSyncMonitor.update(
                phase = LanSyncPhase.IDLE,
                pendingCount = 0,
                message = "已同步，等待配送状态",
                acknowledgedAt = latestAcknowledgement?.acceptedAt
                    ?: LanSyncMonitor.snapshot().lastAcknowledgedAt
            )
        }
    }

    private fun failAttempt(message: String) {
        attemptRunning = false
        cachedEndpoint = null
        if (rerunRequested) {
            rerunRequested = false
            failureCount = 0
            scheduleAttempt(delayMillis = 0L, replaceExisting = true)
            return
        }

        val retryDelay = LanRetryPolicy.delayAfterFailure(failureCount)
        failureCount += 1
        if (retryDelay == null) {
            LanSyncMonitor.update(
                phase = LanSyncPhase.IDLE,
                pendingCount = safePendingCount(),
                message = "$message；等待新事件或网络变化"
            )
        } else {
            scheduleAttempt(delayMillis = retryDelay, replaceExisting = true)
            LanSyncMonitor.update(
                phase = LanSyncPhase.WAITING_RETRY,
                pendingCount = safePendingCount(),
                message = "$message；稍后自动重试"
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun hasLanNetwork(): Boolean = runCatching {
        connectivityManager.allNetworks.any { network ->
            val capabilities = connectivityManager.getNetworkCapabilities(network)
                ?: return@any false
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        }
    }.getOrDefault(false)

    private fun safePendingCount(): Int =
        runCatching { outbox.pendingCount() }.getOrDefault(0)

    private fun dispatch(action: () -> Unit) {
        if (closed.get()) return
        try {
            scheduler.execute {
                if (!closed.get()) action()
            }
        } catch (_: RejectedExecutionException) {
            // A late framework callback raced with Service destruction.
        }
    }

    companion object {
        private const val NETWORK_SETTLE_MILLIS = 300L

        private fun shortError(error: Throwable): String =
            error.localizedMessage?.take(160)
                ?: error.javaClass.simpleName
    }
}

private class AndroidNsdDiscovery(
    context: Context,
    private val scheduler: ScheduledExecutorService
) {
    private val nsdManager = context.getSystemService(NsdManager::class.java)
    private val wifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val finished = AtomicBoolean(false)
    private val discoveryStarted = AtomicBoolean(false)
    private val resolving = AtomicBoolean(false)

    @Volatile
    private var timeout: ScheduledFuture<*>? = null

    @Volatile
    private var multicastLock: WifiManager.MulticastLock? = null

    private var callback: ((Result<LanEndpoint>) -> Unit)? = null

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            discoveryStarted.set(true)
            if (finished.get()) {
                runCatching { nsdManager.stopServiceDiscovery(this) }
            }
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            if (finished.get() || !matchesServiceType(serviceInfo.serviceType)) return
            if (!resolving.compareAndSet(false, true)) return
            @Suppress("DEPRECATION")
            runCatching { nsdManager.resolveService(serviceInfo, resolveListener) }
                .onFailure { complete(Result.failure(it)) }
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

        override fun onDiscoveryStopped(serviceType: String) = Unit

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            complete(Result.failure(IOException("NSD start failed ($errorCode)")))
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
    }

    private val resolveListener = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            complete(Result.failure(IOException("NSD resolve failed ($errorCode)")))
        }

        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                serviceInfo.hostAddresses
            } else {
                @Suppress("DEPRECATION")
                listOfNotNull(serviceInfo.host)
            }.distinctBy(InetAddress::getHostAddress)
            val port = serviceInfo.port
            if (addresses.isEmpty() || port !in 1..65535) {
                complete(Result.failure(IOException("NSD returned no usable endpoint")))
                return
            }
            val network = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                serviceInfo.network
            } else {
                null
            }
            complete(Result.success(LanEndpoint(addresses, port, network)))
        }
    }

    fun start(callback: (Result<LanEndpoint>) -> Unit) {
        check(this.callback == null) { "Discovery already started" }
        this.callback = callback
        multicastLock = runCatching {
            wifiManager?.createMulticastLock("mipopup-nsd")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrNull()
        timeout = scheduler.schedule(
            {
                complete(Result.failure(IOException("NSD discovery timed out")))
            },
            DISCOVERY_TIMEOUT_MILLIS,
            TimeUnit.MILLISECONDS
        )
        runCatching {
            nsdManager.discoverServices(
                SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                discoveryListener
            )
        }.onFailure { complete(Result.failure(it)) }
    }

    fun cancel() {
        complete(result = null)
    }

    private fun complete(result: Result<LanEndpoint>?) {
        if (!finished.compareAndSet(false, true)) return
        timeout?.cancel(false)
        timeout = null
        if (discoveryStarted.get()) {
            runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
        }
        multicastLock?.let { lock ->
            runCatching {
                if (lock.isHeld) lock.release()
            }
        }
        multicastLock = null
        val completion = callback
        callback = null
        if (result != null) completion?.invoke(result)
    }

    private fun matchesServiceType(value: String): Boolean =
        value.trim().trimEnd('.').equals(
            SERVICE_TYPE.trimEnd('.'),
            ignoreCase = true
        )

    companion object {
        private const val SERVICE_TYPE = "_mipopup._tcp."
        private const val DISCOVERY_TIMEOUT_MILLIS = 5_000L
    }
}

private class LanTcpClient {
    @Volatile
    private var activeSocket: Socket? = null

    @Volatile
    private var closed = false

    fun send(endpoint: LanEndpoint, entries: List<LanOutboxEntry>): LanSendResult {
        if (closed) return LanSendResult(emptyList(), "同步客户端已关闭")
        val acknowledgements = mutableListOf<LanAck>()
        val socket = try {
            connect(endpoint)
        } catch (error: Throwable) {
            return LanSendResult(emptyList(), shortError(error))
        }

        return try {
            socket.soTimeout = ACK_TIMEOUT_MILLIS
            socket.tcpNoDelay = true
            entries.forEach { entry ->
                LanFrameCodec.write(socket.getOutputStream(), entry.envelopeJson)
                val acknowledgement = LanProtocol.decodeAck(
                    LanFrameCodec.read(socket.getInputStream())
                ) ?: throw IOException("Mac returned an invalid ACK")
                if (acknowledgement.eventId != entry.eventId) {
                    throw IOException("Mac ACK eventId mismatch")
                }
                acknowledgements += acknowledgement
            }
            LanSendResult(acknowledgements, null)
        } catch (error: Throwable) {
            LanSendResult(acknowledgements, shortError(error))
        } finally {
            if (activeSocket === socket) activeSocket = null
            runCatching { socket.close() }
        }
    }

    fun cancelActive() {
        val socket = activeSocket
        activeSocket = null
        runCatching { socket?.close() }
    }

    fun shutdown() {
        closed = true
        cancelActive()
    }

    private fun connect(endpoint: LanEndpoint): Socket {
        var lastError: Throwable? = null
        endpoint.addresses.forEach { address ->
            if (closed) throw IOException("LAN sync client is closed")
            val socket = Socket()
            activeSocket = socket
            try {
                endpoint.network?.bindSocket(socket)
                socket.connect(
                    InetSocketAddress(address, endpoint.port),
                    CONNECT_TIMEOUT_MILLIS
                )
                return socket
            } catch (error: Throwable) {
                lastError = error
                if (activeSocket === socket) activeSocket = null
                runCatching { socket.close() }
            }
        }
        throw IOException("Unable to connect to discovered Mac", lastError)
    }

    companion object {
        private const val CONNECT_TIMEOUT_MILLIS = 1_500
        private const val ACK_TIMEOUT_MILLIS = 2_500

        private fun shortError(error: Throwable): String =
            error.localizedMessage?.take(160)
                ?: error.javaClass.simpleName
    }
}
