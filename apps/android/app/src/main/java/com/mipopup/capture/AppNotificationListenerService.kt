package com.mipopup.capture

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Local-only adaptation of NotificationForwarder's listener/dedup pipeline.
 * Webhook scheduling and network transmission are intentionally omitted.
 */
class AppNotificationListenerService : NotificationListenerService() {
    private val writer = Executors.newSingleThreadExecutor()
    private val recentContent = LinkedHashMap<String, String>(MAX_RECENT_EVENTS, 0.75f, true)

    override fun onListenerConnected() {
        super.onListenerConnected()
        activeInstance = this
        scanActiveNotifications()
    }

    override fun onListenerDisconnected() {
        if (activeInstance === this) activeInstance = null
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
            .filter { packageName ->
                settings.matches(packageName) || RELEVANT_PACKAGE_HINTS.any(packageName::contains)
            }
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
                progressIndeterminate
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
            .put("groupSummary", (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0)
            .put("ongoing", item.isOngoing)
            .put("clearable", item.isClearable)

        writer.execute { CaptureLogStore(applicationContext).append(record) }
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
        writer.shutdown()
        super.onDestroy()
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
        private val RELEVANT_PACKAGE_HINTS = listOf("meituan", "sankuai", "taobao", "eleme", "miui", "systemui")

        @Volatile
        private var activeInstance: AppNotificationListenerService? = null

        @Volatile
        private var lastActiveScan: ActiveNotificationScanResult? = null

        fun requestActiveSnapshot(): ActiveNotificationScanResult? = activeInstance?.scanActiveNotifications()

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
