package com.mipopup.capture

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var statusText: TextView
    private lateinit var previewText: TextView
    private lateinit var packageEditor: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildContent())
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_EXPORT || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        exportTo(uri)
    }

    private fun buildContent(): ScrollView {
        val scroll = ScrollView(this).apply { setBackgroundColor(Color.rgb(16, 17, 20)) }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(28), dp(20), dp(28))
        }
        scroll.addView(content)

        content.addView(label("MiPopup 通知采集", 26f, true, Color.WHITE))
        content.addView(label(
            "原始通知仅保存在手机；解析后的配送状态会直接发送到同一局域网内的 Mac，不使用服务器或跨网传输。当前内测通道尚未配对加密，请仅在可信网络使用。",
            14f,
            false,
            Color.LTGRAY
        ).withMargin(top = 8))

        statusText = label("正在读取状态…", 15f, false, Color.WHITE)
        content.addView(card(statusText).withMargin(top = 20))

        content.addView(button("1. 打开通知使用权设置") {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }.withMargin(top = 16))

        content.addView(button("2. 扫描当前活动通知") {
            scanActiveNotifications()
        }.withMargin(top = 8))

        content.addView(button("3. 立即重试局域网同步") {
            if (AppNotificationListenerService.requestLanSync()) {
                toast("已请求同步待发送的配送状态")
                statusText.postDelayed({ refresh() }, 500)
            } else {
                NotificationListenerService.requestRebind(listenerComponent())
                toast("监听服务尚未连接，已请求重连")
            }
        }.withMargin(top = 8))

        content.addView(label("目标应用包名（每行一个）", 15f, true, Color.WHITE).withMargin(top = 24))
        packageEditor = EditText(this).apply {
            setText(CaptureSettings(this@MainActivity).targetPackages.sorted().joinToString("\n"))
            setTextColor(Color.WHITE)
            setHintTextColor(Color.GRAY)
            setBackgroundColor(Color.rgb(37, 39, 45))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            minLines = 4
            gravity = Gravity.TOP
        }
        content.addView(packageEditor.withMargin(top = 8))
        content.addView(button("保存目标应用") {
            val parsed = CaptureSettings.parsePackages(packageEditor.text.toString())
            if (parsed.isEmpty()) {
                toast("至少保留一个包名")
            } else {
                CaptureSettings(this).targetPackages = parsed
                toast("已保存 ${parsed.size} 个目标应用")
            }
        }.withMargin(top = 8))

        content.addView(button("4. 导出脱敏 JSONL") { chooseExportTarget() }.withMargin(top = 20))
        content.addView(button("刷新日志预览") { refresh() }.withMargin(top = 8))
        content.addView(button("清空本地日志") {
            worker.execute {
                CaptureLogStore(this).clear()
                runOnUiThread {
                    toast("本地日志已清空")
                    refresh()
                }
            }
        }.withMargin(top = 8))

        content.addView(label("最近事件（已脱敏）", 15f, true, Color.WHITE).withMargin(top = 24))
        previewText = label("尚无日志。请先下单或等待配送状态通知。", 13f, false, Color.LTGRAY)
        content.addView(card(previewText).withMargin(top = 8))

        content.addView(label(
            "采集范围：标题、正文、展开正文、子标题、文本行、通知渠道及时间。原始日志仅存于应用私有目录，保留 7 天且最多 20 MiB；导出时自动脱敏。局域网同步只发送解析后的状态、时间和不可逆订单关联值，不发送原始通知正文。",
            12f,
            false,
            Color.GRAY
        ).withMargin(top = 20))
        return scroll
    }

    private fun refresh() {
        val enabled = isListenerEnabled()
        val activeScan = AppNotificationListenerService.lastActiveScanResult()
        worker.execute {
            val store = CaptureLogStore(this)
            val snapshot = store.snapshot()
            val recent = store.recentRedacted(12)
            val pending = LanOutboxStore(
                File(filesDir, LanOutboxStore.DIRECTORY_NAME)
            ).pendingCount()
            val lanSync = LanSyncMonitor.snapshot()
            runOnUiThread {
                statusText.text = buildString {
                    append(if (enabled) "● 通知读取权限已开启" else "○ 通知读取权限未开启")
                    append("\n已记录 ${snapshot.eventCount} 条事件")
                    append(" · ${formatBytes(snapshot.totalBytes)}")
                    append(" · ${snapshot.fileCount} 个日志文件")
                    append("\n局域网同步：${formatLanPhase(lanSync.phase)} · 待发送 $pending 条")
                    append("\n${lanSync.message}")
                    lanSync.lastAcknowledgedAt?.let {
                        append("\n最近确认：${formatTime(it)}")
                    }
                    if (activeScan != null) {
                        append("\n活动扫描：系统 ${activeScan.totalCount} 条 · 目标 ${activeScan.targetCount} 条")
                        if (activeScan.errorMessage != null) {
                            append("\n扫描错误：${activeScan.errorMessage}")
                        } else if (activeScan.targetCount == 0 && activeScan.relevantPackages.isNotEmpty()) {
                            append("\n相关包：${activeScan.relevantPackages.joinToString("、")}")
                        }
                    }
                }
                statusText.setTextColor(if (enabled) Color.rgb(112, 220, 146) else Color.rgb(255, 184, 108))
                previewText.text = if (recent.isEmpty()) {
                    "尚无日志。请先下单或等待配送状态通知。"
                } else {
                    recent.joinToString("\n\n")
                }
            }
        }
    }

    private fun scanActiveNotifications() {
        val result = AppNotificationListenerService.requestActiveSnapshot()
        if (result == null) {
            NotificationListenerService.requestRebind(listenerComponent())
            toast("监听服务尚未连接，已请求重连；请稍后再扫描")
            return
        }

        val message = when {
            result.errorMessage != null -> "扫描失败：${result.errorMessage}"
            result.targetCount == 0 -> "系统返回 ${result.totalCount} 条活动通知，但没有匹配目标包"
            result.capturedCount == 0 -> "找到 ${result.targetCount} 条目标通知，内容与已有记录相同"
            else -> "找到 ${result.targetCount} 条目标通知，新增 ${result.capturedCount} 条记录"
        }
        toast(message)
        statusText.postDelayed({ refresh() }, 500)
    }

    private fun chooseExportTarget() {
        val timestamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/x-ndjson"
            putExtra(Intent.EXTRA_TITLE, "mipopup-notifications-$timestamp.jsonl")
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_EXPORT)
    }

    private fun exportTo(uri: Uri) {
        worker.execute {
            val result = runCatching {
                contentResolver.openOutputStream(uri, "wt")?.use { stream ->
                    CaptureLogStore(this).exportRedacted(stream)
                } ?: error("无法打开导出位置")
            }
            runOnUiThread {
                result.onSuccess { toast("已导出 $it 条脱敏事件") }
                    .onFailure { toast("导出失败：${it.message}") }
            }
        }
    }

    private fun isListenerEnabled(): Boolean {
        val expected = listenerComponent().flattenToString()
        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners").orEmpty()
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    private fun listenerComponent() = ComponentName(this, AppNotificationListenerService::class.java)

    private fun label(text: String, size: Float, bold: Boolean, color: Int) = TextView(this).apply {
        this.text = text
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setLineSpacing(0f, 1.15f)
    }

    private fun button(text: String, action: () -> Unit) = Button(this).apply {
        this.text = text
        isAllCaps = false
        setOnClickListener { action() }
    }

    private fun card(child: TextView) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(14), dp(16), dp(14))
        setBackgroundColor(Color.rgb(37, 39, 45))
        addView(child)
    }

    private fun <T : android.view.View> T.withMargin(top: Int = 0): T {
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(top) }
        return this
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun formatBytes(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "%.1f KiB".format(bytes / 1024.0)
        else -> "%.1f MiB".format(bytes / (1024.0 * 1024.0))
    }

    private fun formatLanPhase(phase: LanSyncPhase): String = when (phase) {
        LanSyncPhase.STOPPED -> "未连接"
        LanSyncPhase.IDLE -> "待机"
        LanSyncPhase.DISCOVERING -> "发现 Mac"
        LanSyncPhase.SENDING -> "正在发送"
        LanSyncPhase.WAITING_RETRY -> "等待重试"
    }

    private fun formatTime(timestamp: Long): String =
        SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(timestamp))

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()

    companion object {
        private const val REQUEST_EXPORT = 2001
    }
}
