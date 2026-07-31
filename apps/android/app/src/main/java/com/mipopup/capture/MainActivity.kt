package com.mipopup.capture

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.text.InputType
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
    private lateinit var customRuleEditor: EditText
    private lateinit var relayEditor: EditText

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
            "原始通知仅保存在手机。解析后的最小配送状态优先直连同一局域网内的 Mac；配置个人中继后，也会使用端到端加密跨网同步，中继服务器无法读取状态正文。",
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

        content.addView(button("4. 发送测试配送状态到 Mac") {
            sendNetworkSyncTest()
        }.withMargin(top = 8))

        content.addView(button("5. 允许锁屏后台同步") {
            requestLockScreenSyncPermission()
        }.withMargin(top = 8))

        content.addView(button("打开 MiPopup 应用设置") {
            startActivity(Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            ))
        }.withMargin(top = 8))

        content.addView(label(
            "HyperOS 还需在应用设置中将电量策略设为“无限制”，并允许应用自启动，否则系统仍可能在锁屏后暂停通知监听和局域网访问。",
            12f,
            false,
            Color.GRAY
        ).withMargin(top = 8))

        content.addView(label("监听来源应用包名（每行一个）", 15f, true, Color.WHITE).withMargin(top = 24))
        content.addView(label(
            "内置的美团、淘宝闪购和饿了么规则会使用这些来源。自定义规则中的包名会自动加入监听范围，无需在这里重复填写。",
            12f,
            false,
            Color.GRAY
        ).withMargin(top = 6))
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

        content.addView(label("自定义配送解析规则", 15f, true, Color.WHITE).withMargin(top = 24))
        content.addView(label(
            "可为任意通知应用设置包名、标准通知或 HyperOS 焦点格式、状态关键词和是否同步到 Mac。规则按顺序匹配，先命中的规则优先；只会同步状态、预计时间和不可逆关联值，不发送通知原文。",
            12f,
            false,
            Color.GRAY
        ).withMargin(top = 6))
        customRuleEditor = EditText(this).apply {
            setText(CustomDeliveryRuleCodec.encode(CaptureSettings(this@MainActivity).customDeliveryRules))
            setTextColor(Color.WHITE)
            setHintTextColor(Color.GRAY)
            setBackgroundColor(Color.rgb(37, 39, 45))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            minLines = 10
            gravity = Gravity.TOP
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        }
        content.addView(customRuleEditor.withMargin(top = 8))
        content.addView(button("填入自定义规则示例") {
            customRuleEditor.setText(CustomDeliveryRuleCodec.example())
        }.withMargin(top = 8))
        content.addView(button("保存自定义解析规则") { saveCustomDeliveryRules() }.withMargin(top = 8))

        content.addView(label("个人 VPS 中继（可选）", 15f, true, Color.WHITE).withMargin(top = 24))
        content.addView(label(
            "粘贴部署脚本生成的完整客户端 JSON。凭据由 Android Keystore 加密保存，并在此编辑框中回显，便于查看和修改当前配置。",
            12f,
            false,
            Color.GRAY
        ).withMargin(top = 6))
        relayEditor = EditText(this).apply {
            hint = "{\n  \"baseURL\": \"https://relay.example.com\",\n  \"channelId\": \"...\",\n  \"token\": \"...\",\n  \"encryptionKey\": \"...\"\n}"
            setText(
                RelaySettings(this@MainActivity).load()
                    ?.let(RelayProtocol::encodeConfiguration)
                    .orEmpty()
            )
            setTextColor(Color.WHITE)
            setHintTextColor(Color.DKGRAY)
            setBackgroundColor(Color.rgb(37, 39, 45))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            minLines = 6
            gravity = Gravity.TOP
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        }
        content.addView(relayEditor.withMargin(top = 8))
        content.addView(button("保存中继配置并立即同步") { saveRelayConfiguration() }.withMargin(top = 8))
        content.addView(button("删除中继配置") { clearRelayConfiguration() }.withMargin(top = 8))

        content.addView(button("6. 导出脱敏 JSONL") { chooseExportTarget() }.withMargin(top = 20))
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
            "采集范围：标题、正文、展开正文、子标题、文本行、通知渠道及时间。原始日志仅存于应用私有目录，保留 7 天且最多 20 MiB；导出时自动脱敏。网络同步只发送解析后的状态、时间和不可逆订单关联值，不发送原始通知正文。",
            12f,
            false,
            Color.GRAY
        ).withMargin(top = 20))
        return scroll
    }

    private fun refresh() {
        val enabled = isListenerEnabled()
        val lockScreenSyncAllowed = isIgnoringBatteryOptimizations()
        val activeScan = AppNotificationListenerService.lastActiveScanResult()
        worker.execute {
            val store = CaptureLogStore(this)
            val snapshot = store.snapshot()
            val recent = store.recentRedacted(12)
            val pending = LanOutboxStore(
                File(filesDir, LanOutboxStore.DIRECTORY_NAME)
            ).pendingCount()
            val lanSync = LanSyncMonitor.snapshot()
            val relayConfigured = RelaySettings(this).load() != null
            val customRules = CaptureSettings(this).customDeliveryRules
            val relayPending = LanOutboxStore(
                File(filesDir, RelayProtocol.OUTBOX_DIRECTORY_NAME)
            ).pendingCount()
            val relaySync = RelaySyncMonitor.snapshot()
            runOnUiThread {
                statusText.text = buildString {
                    append(if (enabled) "● 通知读取权限已开启" else "○ 通知读取权限未开启")
                    append("\n已记录 ${snapshot.eventCount} 条事件")
                    append(" · ${formatBytes(snapshot.totalBytes)}")
                    append(" · ${snapshot.fileCount} 个日志文件")
                    append("\n局域网同步：${formatLanPhase(lanSync.phase)} · 待发送 $pending 条")
                    append(if (lockScreenSyncAllowed) "\n锁屏同步：系统省电限制已关闭" else "\n锁屏同步：受系统省电限制")
                    append("\n${lanSync.message}")
                    lanSync.lastAcknowledgedAt?.let {
                        append("\n最近确认：${formatTime(it)}")
                    }
                    append("\n公网中继：${if (relayConfigured) formatRelayPhase(relaySync.phase) else "未配置"}")
                    append(" · 待发送 $relayPending 条")
                    append("\n${relaySync.message}")
                    relaySync.lastAcknowledgedAt?.let {
                        append("\n中继最近确认：${formatTime(it)}")
                    }
                    if (customRules.isNotEmpty()) {
                        append("\n自定义规则：${customRules.size} 条 · ${customRules.count { it.syncToMac }} 条同步到 Mac")
                    }
                    if (activeScan != null) {
                        append("\n活动扫描：系统 ${activeScan.totalCount} 条 · 目标 ${activeScan.targetCount} 条")
                        if (activeScan.errorMessage != null) {
                            append("\n扫描错误：${activeScan.errorMessage}")
                        } else if (activeScan.targetCount == 0 && activeScan.relevantPackages.isNotEmpty()) {
                            append("\n当前通知来源：${activeScan.relevantPackages.take(12).joinToString("、")}")
                            if (activeScan.relevantPackages.size > 12) append(" 等 ${activeScan.relevantPackages.size} 个")
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
            result.targetCount == 0 -> "系统返回 ${result.totalCount} 条活动通知；可从状态卡复制来源包名"
            result.capturedCount == 0 -> "找到 ${result.targetCount} 条目标通知，内容与已有记录相同"
            else -> "找到 ${result.targetCount} 条目标通知，新增 ${result.capturedCount} 条记录"
        }
        toast(message)
        statusText.postDelayed({ refresh() }, 500)
    }

    private fun saveRelayConfiguration() {
        val raw = relayEditor.text.toString().trim()
        if (raw.isEmpty()) {
            toast("请先粘贴完整的中继客户端 JSON")
            return
        }
        worker.execute {
            val result = runCatching {
                val configuration = RelayProtocol.parseConfiguration(raw)
                RelaySettings(this).save(configuration)
                configuration to AppNotificationListenerService.requestRelaySyncReload()
            }
            runOnUiThread {
                result.onSuccess { (configuration, syncRequested) ->
                    relayEditor.setText(RelayProtocol.encodeConfiguration(configuration))
                    toast(
                        if (syncRequested) {
                            "中继配置已加密保存，已请求同步"
                        } else {
                            "中继配置已保存；通知服务连接后会自动同步"
                        }
                    )
                    refresh()
                }.onFailure { toast("保存失败：${it.localizedMessage ?: it.javaClass.simpleName}") }
            }
        }
    }

    private fun sendNetworkSyncTest() {
        if (AppNotificationListenerService.requestNetworkSyncTest()) {
            toast("测试配送状态已写入日志，并通过可用路线发送到 Mac")
            statusText.postDelayed({ refresh() }, 600)
            statusText.postDelayed({ refresh() }, 2_000)
        } else {
            NotificationListenerService.requestRebind(listenerComponent())
            toast("监听服务尚未连接，已请求重连；请稍后再次测试")
        }
    }

    private fun saveCustomDeliveryRules() {
        val result = runCatching {
            val rules = CustomDeliveryRuleCodec.decode(customRuleEditor.text.toString())
            CaptureSettings(this).customDeliveryRules = rules
            rules
        }
        result.onSuccess { rules ->
            customRuleEditor.setText(CustomDeliveryRuleCodec.encode(rules))
            toast("已保存 ${rules.size} 条自定义规则，其中 ${rules.count { it.syncToMac }} 条会同步到 Mac")
            refresh()
        }.onFailure { error ->
            toast("规则格式无效：${error.localizedMessage ?: error.javaClass.simpleName}")
        }
    }

    private fun clearRelayConfiguration() {
        worker.execute {
            val result = runCatching {
                RelaySettings(this).clear()
                AppNotificationListenerService.requestRelaySyncReload()
            }
            runOnUiThread {
                result.onSuccess {
                    relayEditor.text.clear()
                    toast("中继配置已删除；局域网同步不受影响")
                    refresh()
                }.onFailure { toast("删除失败：${it.localizedMessage ?: it.javaClass.simpleName}") }
            }
        }
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

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(PowerManager::class.java)
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestLockScreenSyncPermission() {
        if (isIgnoringBatteryOptimizations()) {
            toast("系统省电限制已经关闭；请再确认 HyperOS 自启动和电量策略为无限制")
            return
        }
        val request = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName")
        )
        runCatching { startActivity(request) }
            .onFailure {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
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

    private fun formatRelayPhase(phase: RelaySyncPhase): String = when (phase) {
        RelaySyncPhase.STOPPED -> "未连接"
        RelaySyncPhase.IDLE -> "待机"
        RelaySyncPhase.SENDING -> "正在发送"
        RelaySyncPhase.WAITING_RETRY -> "等待重试"
    }

    private fun formatTime(timestamp: Long): String =
        SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(timestamp))

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()

    companion object {
        private const val REQUEST_EXPORT = 2001
    }
}
