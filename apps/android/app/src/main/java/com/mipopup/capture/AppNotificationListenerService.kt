package com.mipopup.capture

import android.app.Notification
import android.os.PowerManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.Executors

/**
 * NotificationForwarder-style listener/dedup pipeline. Only normalized delivery
 * updates enter LAN or end-to-end encrypted relay synchronization.
 */
class AppNotificationListenerService : NotificationListenerService() {
    private data class DeliveryEnqueueResult(
        val lanEnqueued: Boolean,
        val relayEnqueued: Boolean
    )

    private val writer = Executors.newSingleThreadExecutor()
    private val recentContent = LinkedHashMap<String, String>(MAX_RECENT_EVENTS, 0.75f, true)

    private lateinit var outbox: LanOutboxStore
    private lateinit var relayOutbox: LanOutboxStore
    private lateinit var identityStore: LanIdentityStore
    private lateinit var captureWakeLock: PowerManager.WakeLock

    @Volatile
    private var lanSync: LanSyncCoordinator? = null

    @Volatile
    private var relaySync: RelaySyncCoordinator? = null

    override fun onCreate() {
        super.onCreate()
        runCatching { BundledRelayConfiguration.installIfNeeded(applicationContext) }
        outbox = LanOutboxStore(File(filesDir, LanOutboxStore.DIRECTORY_NAME))
        relayOutbox = LanOutboxStore(File(filesDir, RelayProtocol.OUTBOX_DIRECTORY_NAME))
        identityStore = LanIdentityStore(applicationContext)
        captureWakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:delivery-capture")
            .apply { setReferenceCounted(false) }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        activeInstance = this
        lanSync?.close()
        lanSync = LanSyncCoordinator(applicationContext, outbox).also(LanSyncCoordinator::start)
        restartRelaySync()
        scanActiveNotifications()
    }

    override fun onListenerDisconnected() {
        if (activeInstance === this) activeInstance = null
        lanSync?.close()
        lanSync = null
        relaySync?.close()
        relaySync = null
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        captureNotification(sbn ?: return, "posted")
    }

    fun scanActiveNotifications(): ActiveNotificationScanResult {
        val settings = CaptureSettings(applicationContext)
        val items = runCatching { activeNotifications?.toList().orEmpty() }
            .getOrElse { error ->
                return ActiveNotificationScanResult(
                    totalCount = 0,
                    targetCount = 0,
                    capturedCount = 0,
                    relevantPackages = emptyList(),
                    errorMessage = error.localizedMessage ?: "系统拒绝读取活动通知"
                ).also { lastActiveScan = it }
        }
        val relevantPackages = items.map(StatusBarNotification::getPackageName)
            .distinct()
            .sorted()
        val targets = items.filter { settings.matches(it.packageName) }
        val captured = targets.count { captureNotification(it, "active") }
        return ActiveNotificationScanResult(
            totalCount = items.size,
            targetCount = targets.size,
            capturedCount = captured,
            relevantPackages = relevantPackages,
            errorMessage = null
        ).also { lastActiveScan = it }
    }

    fun enqueueNetworkSyncTest(): Boolean {
        val now = System.currentTimeMillis()
        val eventId = UUID.randomUUID().toString()
        val orderKey = sha256("mipopup-network-test:$eventId")
        val update = DeliveryUpdate.networkSyncTest(
            eventId = eventId,
            capturedAt = now,
            orderKey = orderKey,
            sourcePackage = packageName
        )
        val record = JSONObject()
            .put("schemaVersion", 1)
            .put("eventId", eventId)
            .put("eventKind", "test")
            .put("capturedAt", now)
            .put("postedAt", now)
            .put("sourcePackage", packageName)
            .put("appName", "MiPopup 测试")
            .put("notificationKeyHash", orderKey)
            .put("notificationId", -1)
            .put("title", "网络同步测试")
            .put("text", "测试配送状态已加入局域网和公网中继队列")
            .put("delivery", update.toJson())
            .put("deliverySyncEnabled", true)

        acquireCaptureWakeLock()
        writer.execute {
            val result = enqueueDeliveryUpdate(update)
            try {
                CaptureLogStore(applicationContext).append(record)
            } finally {
                if (result.lanEnqueued) lanSync?.kick()
                if (result.relayEnqueued) relaySync?.kick()
                releaseCaptureWakeLock()
            }
        }
        return true
    }

    private fun captureNotification(item: StatusBarNotification, initialEventKind: String): Boolean {
        val settings = CaptureSettings(applicationContext)
        if (!settings.matches(item.packageName)) return false

        val notification = item.notification
        val extras = notification.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        val bigText = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty()
        val subText = extras?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty()
        val textLines = extras?.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.map(CharSequence::toString)
            .orEmpty()
        val tickerText = notification.tickerText?.toString().orEmpty()
        val progress = extras?.getInt(Notification.EXTRA_PROGRESS, 0) ?: 0
        val progressMax = extras?.getInt(Notification.EXTRA_PROGRESS_MAX, 0) ?: 0
        val progressIndeterminate = extras?.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false) ?: false
        val groupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        val focusParam = runCatching { extras?.getString(HyperOSFocusNotification.EXTRA_PARAM) }
            .getOrNull()
            ?.takeIf(String::isNotBlank)
            ?.takeIf { it.length <= HyperOSFocusNotification.MAX_PARAM_LENGTH }

        val keyHash = sha256("${settings.keySalt}:${item.key}")
        val contentHash = sha256(
            listOf(
                title,
                text,
                bigText,
                subText,
                textLines.joinToString("\u001f"),
                tickerText,
                progress,
                progressMax,
                progressIndeterminate,
                focusParam.orEmpty()
            )
        )
        val eventKind = synchronized(recentContent) {
            val previous = recentContent.put(keyHash, contentHash)
            trimRecent()
            when {
                previous == null -> initialEventKind
                previous == contentHash -> "duplicate"
                else -> "updated"
            }
        }
        if (eventKind == "duplicate") return false

        val record = baseRecord(item, keyHash, eventKind)
            .put("title", title)
            .put("text", text)
            .put("bigText", bigText)
            .put("subText", subText)
            .put("textLines", JSONArray(textLines))
            .put("category", notification.category ?: "")
            .put("channelId", notification.channelId ?: "")
            .put("tickerText", tickerText)
            .put("extrasKeys", JSONArray(extras?.keySet()?.sorted().orEmpty()))
            .put("progress", progress)
            .put("progressMax", progressMax)
            .put("progressIndeterminate", progressIndeterminate)
            .put("groupKey", item.groupKey ?: "")
            .put("tag", item.tag ?: "")
            .put("groupSummary", groupSummary)
            .put("ongoing", item.isOngoing)
            .put("clearable", item.isClearable)
            .also { json -> focusParam?.let { json.put("focusParam", it) } }

        val parsedDelivery = DeliveryNotificationParser.parseConfigured(
            DeliveryNotificationInput(
                eventId = record.getString("eventId"),
                eventKind = eventKind,
                capturedAt = record.getLong("capturedAt"),
                sourcePackage = item.packageName,
                notificationKeyHash = keyHash,
                title = title,
                text = text,
                bigText = bigText,
                subText = subText,
                textLines = textLines,
                groupSummary = groupSummary,
                focusParam = focusParam
            ),
            settings.customDeliveryRules
        )
        val deliveryUpdate = parsedDelivery?.update
        deliveryUpdate?.let { record.put("delivery", it.toJson()) }
        parsedDelivery?.let { parsed ->
            record.put("deliverySyncEnabled", parsed.syncToMac)
        }
        if (parsedDelivery?.syncToMac == true) acquireCaptureWakeLock()

        writer.execute {
            val result = parsedDelivery
                ?.takeIf { it.syncToMac }
                ?.let { enqueueDeliveryUpdate(it.update) }
                ?: DeliveryEnqueueResult(lanEnqueued = false, relayEnqueued = false)

            try {
                CaptureLogStore(applicationContext).append(record)
            } finally {
                if (result.lanEnqueued) lanSync?.kick()
                if (result.relayEnqueued) relaySync?.kick()
                if (parsedDelivery?.syncToMac == true) releaseCaptureWakeLock()
            }
        }
        return true
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        val item = sbn ?: return
        val settings = CaptureSettings(applicationContext)
        if (!settings.matches(item.packageName)) return
        val keyHash = sha256("${settings.keySalt}:${item.key}")
        synchronized(recentContent) { recentContent.remove(keyHash) }
        val record = baseRecord(item, keyHash, "removed")
        writer.execute { CaptureLogStore(applicationContext).append(record) }
    }

    override fun onDestroy() {
        if (activeInstance === this) activeInstance = null
        lanSync?.close()
        lanSync = null
        relaySync?.close()
        relaySync = null
        releaseCaptureWakeLock()
        writer.shutdown()
        super.onDestroy()
    }

    private fun acquireCaptureWakeLock() {
        runCatching { captureWakeLock.acquire(CAPTURE_WAKE_LOCK_TIMEOUT_MILLIS) }
    }

    private fun restartRelaySync() {
        relaySync?.close()
        relaySync = null
        val configuration = RelaySettings(applicationContext).load()
        if (configuration == null) {
            RelaySyncMonitor.update(
                RelaySyncPhase.STOPPED,
                runCatching { relayOutbox.pendingCount() }.getOrDefault(0),
                "公网中继尚未配置"
            )
            return
        }
        relaySync = RelaySyncCoordinator(
            applicationContext,
            relayOutbox,
            configuration
        ).also(RelaySyncCoordinator::start)
    }

    private fun releaseCaptureWakeLock() {
        runCatching {
            if (::captureWakeLock.isInitialized && captureWakeLock.isHeld) {
                captureWakeLock.release()
            }
        }
    }

    private fun enqueueDeliveryUpdate(update: DeliveryUpdate): DeliveryEnqueueResult {
        val entry = runCatching {
            val sequence = identityStore.nextSequence()
            val envelope = LanProtocol.encodeDeliveryUpdate(
                deviceId = identityStore.deviceId(),
                sequence = sequence,
                sentAt = System.currentTimeMillis(),
                deliveryUpdateJson = update.toJson().toString()
            )
            LanOutboxEntry(
                eventId = update.eventId,
                sequence = sequence,
                envelopeJson = envelope
            )
        }.onFailure { error ->
            LanSyncMonitor.update(
                phase = LanSyncPhase.IDLE,
                pendingCount = runCatching { outbox.pendingCount() }.getOrDefault(0),
                message = "配送状态封装失败：${error.localizedMessage ?: error.javaClass.simpleName}"
            )
        }.getOrNull() ?: return DeliveryEnqueueResult(false, false)

        val lanEnqueued = runCatching { outbox.enqueue(entry) }
            .onFailure { error ->
                LanSyncMonitor.update(
                    LanSyncPhase.IDLE,
                    runCatching { outbox.pendingCount() }.getOrDefault(0),
                    "局域网入队失败：${error.localizedMessage ?: error.javaClass.simpleName}"
                )
            }.getOrDefault(false)
        val relayEnqueued = runCatching { relayOutbox.enqueue(entry) }
            .onFailure { error ->
                RelaySyncMonitor.update(
                    RelaySyncPhase.IDLE,
                    runCatching { relayOutbox.pendingCount() }.getOrDefault(0),
                    "中继入队失败：${error.localizedMessage ?: error.javaClass.simpleName}"
                )
            }.getOrDefault(false)
        return DeliveryEnqueueResult(lanEnqueued, relayEnqueued)
    }

    private fun baseRecord(
        item: StatusBarNotification,
        keyHash: String,
        eventKind: String
    ): JSONObject = JSONObject()
        .put("schemaVersion", 1)
        .put("eventId", UUID.randomUUID().toString())
        .put("eventKind", eventKind)
        .put("capturedAt", System.currentTimeMillis())
        .put("postedAt", item.postTime)
        .put("sourcePackage", item.packageName)
        .put("appName", resolveAppName(item.packageName))
        .put("notificationKeyHash", keyHash)
        .put("notificationId", item.id)

    private fun resolveAppName(packageName: String): String = runCatching {
        val info = packageManager.getApplicationInfo(packageName, 0)
        packageManager.getApplicationLabel(info).toString()
    }.getOrDefault(packageName)

    private fun trimRecent() {
        while (recentContent.size > MAX_RECENT_EVENTS) {
            recentContent.remove(recentContent.entries.first().key)
        }
    }

    private fun sha256(value: Any): String {
        val bytes = MessageDigest.getInstance("SHA-256")
            .digest(value.toString().toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { byte -> "%02x".format(byte) }
    }

    companion object {
        private const val MAX_RECENT_EVENTS = 512
        private const val CAPTURE_WAKE_LOCK_TIMEOUT_MILLIS = 15_000L
        @Volatile
        private var activeInstance: AppNotificationListenerService? = null

        @Volatile
        private var lastActiveScan: ActiveNotificationScanResult? = null

        fun requestActiveSnapshot(): ActiveNotificationScanResult? = activeInstance?.scanActiveNotifications()

        fun requestLanSync(): Boolean {
            val coordinator = activeInstance?.lanSync ?: return false
            coordinator.kick()
            return true
        }

        fun requestRelaySyncReload(): Boolean {
            val service = activeInstance ?: return false
            service.restartRelaySync()
            service.relaySync?.kick()
            return true
        }

        fun requestNetworkSyncTest(): Boolean =
            activeInstance?.enqueueNetworkSyncTest() ?: false

        fun lastActiveScanResult(): ActiveNotificationScanResult? = lastActiveScan
    }
}

data class ActiveNotificationScanResult(
    val totalCount: Int,
    val targetCount: Int,
    val capturedCount: Int,
    val relevantPackages: List<String>,
    val errorMessage: String?
)
