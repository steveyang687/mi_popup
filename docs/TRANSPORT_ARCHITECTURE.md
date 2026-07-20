# MiPopup 同局域网传输方案

## 当前结论

首版只实现 Android 到 Mac 的同局域网状态推送：

1. Mac 启动被动 TCP listener，并通过 Bonjour 发布 `_mipopup._tcp` 服务。
2. Android 通过 `NsdManager` 发现 Mac。
3. Android 的 `NotificationListenerService` 捕获通知后立即在手机本地解析。
4. 只有命中保守规则的归一化 `DeliveryUpdate` 才进入网络发送。
5. Android 主动建立短连接，发送长度分帧的 JSON envelope；Mac 校验并返回 ACK。

Mac 不轮询手机，不请求原始通知，不使用固定刷新周期，也不发送心跳。当前没有 VPS、云服务、NAT 打洞、中继或跨网回退；两端不在同一局域网时不会同步。

## 数据流

```text
Android NotificationListenerService 回调
  -> 包名白名单
  -> DeliveryNotificationParser
  -> 归一化 DeliveryUpdate
  -> 立即尝试 Bonjour/NSD 局域网发送
  -> Mac 解码、校验并按 eventId 去重
  -> Mac 返回 ACK
  -> 更新刘海 UI
```

原始采集日志仍只写入 Android 应用私有目录。网络层不发送原始通知 `title`、`text`、`bigText`、地址、手机号、完整订单号、通知图片、action 或 `PendingIntent`。

## 服务发现与连接

- Bonjour/NSD service type 固定为 `_mipopup._tcp`。
- Bonjour 实例名和 TXT record 不携带订单、账号、通知正文或密钥。
- Android 是唯一连接发起方，Mac 是唯一监听方。
- Android 缓存当前网络中已经解析的 endpoint；Wi-Fi 切换、服务丢失或连接失败后缓存失效。
- 未命中缓存时启动有界 NSD discovery，找到目标服务后立即停止，不永久扫描局域网。
- 当前仅接受同一局域网发现到的服务，不允许配置公网地址，也不尝试蜂窝网络、VPN、tailnet 或服务器地址。

## 帧与消息

应用层使用 TCP。每帧为：

```text
4-byte unsigned big-endian JSON length
+ exactly that many UTF-8 JSON bytes
```

长度不包含 4 字节前缀。首版单帧上限为 16 KiB。接收方必须处理 TCP 拆包和粘包，不能把单次读取结果当作一帧。

Android 发送：

- `protocolVersion = 1`
- `type = "delivery_update"`
- 安装级 UUID `deviceId`
- 从 `1` 开始单调递增的正整数 `sequence`
- Unix epoch milliseconds 格式的 `sentAt`
- `payload` 为 `delivery-update-v1`

Mac 接收并校验成功后返回：

- `protocolVersion = 1`
- `type = "ack"`
- 与 `payload.eventId` 相同的 `eventId`
- `status = "accepted"` 或 `"duplicate"`
- Unix epoch milliseconds 格式的 `acceptedAt`

完整契约见：

- `protocol/PROTOCOL.md`
- `protocol/schemas/delivery-update-v1.schema.json`
- `protocol/schemas/sync-envelope-v1.schema.json`
- `protocol/schemas/sync-ack-v1.schema.json`

## 实时性与功耗

首版采用“事件到达即上报”，而不是高频轮询：

- Android 收到目标通知并完成解析后立即发送，正常局域网条件下无需等待下一次刷新。
- Mac listener 由 Network.framework 的网络事件唤醒；空闲时没有应用层轮询或心跳。
- Android 不维护永久长连接。短时间内的连续通知可以复用当前发送任务，完成后释放连接。
- NSD discovery 是有界操作；找到服务、超时或发送任务取消后必须停止。
- 失败重试次数有限并使用递增等待，不进行无限紧密重连。
- 有限重试结束后，后续配送通知、网络变化或 Android 页面中的手动重试会再次触发 Outbox 发送。
- 无法送达时保留待发事件；后续目标通知或网络恢复事件可再次触发发送。

Android 深度 Doze、厂商省电策略或 Mac 睡眠仍可能延迟传输。本阶段目标是兼顾通知到达时的低延迟和空闲时的低功耗，不承诺系统休眠期间绝对实时。

## 可靠性边界

- `eventId` 是投递幂等键；Mac 对重复 `eventId` 只确认一次，不重复播放动画。
- Android 只有收到匹配 ACK 后才将事件视为送达。
- 连接失败、写入失败、ACK 超时或 ACK 不匹配都视为本次投递失败。
- 重试不能依赖两端时钟完全一致；`capturedAt` 和 `acceptedAt` 只用于展示与诊断。
- `removed` 通知不会生成 `DeliveryUpdate`，也不会被解释为送达或取消。
- 首版只传单个 `delivery_update` envelope，不提供历史日志同步、远程查询、订单快照或 Mac 到 Android 的控制消息。

## 当前安全边界

首版 LAN Beta 是明文且未认证的 TCP 协议：

- 同一局域网中的其他设备可能观察配送状态、ETA、来源包名和事件时间。
- 恶意设备可能伪装成 Mac、连接 Mac listener、伪造事件或阻断同步。
- 仅传最小化 `DeliveryUpdate` 能降低泄露影响，但不能替代加密和身份认证。

因此当前版本只适用于本人控制的可信局域网测试。不要在公共 Wi-Fi、访客网络、公司共享网络或其他不可信网络中启用，也不要为 Mac listener 配置路由器端口映射或公网防火墙放行；UI 和发布说明不得宣称“端到端加密”“安全配对”或“已认证设备”。

公开发布前的强制门禁：

1. 显式设备配对，并能查看、撤销已配对设备。
2. Android Keystore 与 macOS Keychain 保存设备凭据。
3. 使用经过评审的认证加密通道，防止窃听、篡改、伪造和重放。
4. Bonjour 广播不包含 secret；配对材料短期、单次有效。
5. 错误认证不能自动降级为明文。
6. 真机覆盖首次授权、错误凭据、重放、解绑和密钥轮换测试。

## 平台权限

Android 当前目标 API 36：

- `android.permission.INTERNET`：建立局域网 TCP 连接。
- `android.permission.ACCESS_NETWORK_STATE`：监听网络变化并约束发送时机。
- `android.permission.ACCESS_WIFI_STATE`：访问 Wi-Fi/NSD 兼容路径所需的网络状态。
- 旧 Android 版本若需要显式 `WifiManager.MulticastLock` 接收 mDNS，再声明 `android.permission.CHANGE_WIFI_MULTICAST_STATE`，且只在 discovery 窗口持有。
- `ACCESS_LOCAL_NETWORK` 是 target API 37+ 的运行时权限；当前 target API 36 不提前声明。

macOS：

- `Info.plist` 提供 `NSLocalNetworkUsageDescription`。
- `NSBonjourServices` 列出 `_mipopup._tcp`。
- 如果未来启用 App Sandbox，监听入站连接需要 `com.apple.security.network.server`。
- 普通固定 service type 的 Bonjour 在 macOS 不需要 multicast entitlement。

macOS 15+ 的局域网授权与应用代码签名身份相关。终端启动的开发进程可能不能代表实际打包应用的权限行为，因此必须用打包后的 `.app` 验证允许、拒绝、重新启动和网络切换。

## 明确未实现

以下能力不属于当前版本，也没有隐藏或自动回退路径：

- 互联网或蜂窝网络同步
- 公网 VPS
- Tailscale 或 Headscale
- STUN、NAT 打洞或端口映射
- DERP、TURN 或其他服务器中继
- WebRTC DataChannel
- 云端暂存、推送通知或账号体系
- 设备配对、TLS、mTLS 或应用层加密

未来如果重新启动跨网设计，必须作为独立阶段重新评审服务器保留策略、端到端加密、凭据恢复、滥用防护和运维成本，不能静默改变当前“无云端”的产品边界。

## 上游资料

- [Android Network Service Discovery](https://developer.android.com/develop/connectivity/wifi/use-nsd)
- [Android NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager)
- [Android Local network permission](https://developer.android.com/privacy-and-security/local-network-permission)
- [Android WorkManager retry and backoff](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)
- [Android Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)
- [Apple local network privacy TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
- [Apple NWListener Bonjour service](https://developer.apple.com/documentation/network/nwlistener/service-swift.struct)
