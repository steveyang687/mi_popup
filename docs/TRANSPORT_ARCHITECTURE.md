# MiPopup 双通道传输架构

## 当前结论

Android 对每一条归一化 `DeliveryUpdate` 同时维护两个独立的可靠投递队列：

1. **LAN 直连**：Mac 通过 Bonjour 发布 `_mipopup._tcp`，Android 发现后使用短 TCP 连接推送并等待 ACK。
2. **个人 VPS Relay**：Android 使用 HTTPS POST 主动上传 AES-256-GCM 密文；Mac 使用出站 WSS 长连接接收、认证解密并 ACK。

LAN 仍是同网环境下的低延迟路径。Relay 解决蜂窝网络、不同 Wi-Fi 和 Android 上其他 VPN 占用系统 VPN 槽位时的同步问题。两条路径复用同一个 `eventId`，Mac 进入同一个 `RecentDeliveryStore` 去重，所以不会重复展示。

## 数据流

```text
NotificationListenerService callback
  -> package allowlist
  -> DeliveryNotificationParser
  -> normalized DeliveryUpdate only
  -> shared LAN envelope + eventId
       |-> LAN outbox -> NSD/TCP -> Mac -> LAN ACK
       `-> Relay outbox -> AES-GCM -> HTTPS -> VPS ciphertext SQLite
                                              -> WSS -> Mac decrypt/validate
                                              -> shared dedupe/store -> HTTPS ACK
```

原始采集日志仍只写入 Android 应用私有目录。任何网络路径都不发送原始 `title/text/bigText`、地址、手机号、完整订单号、通知图片、action 或 `PendingIntent`。

## 实时性与功耗

- Android 收到目标通知并完成解析后立即 kick 两个 outbox，不依赖 Mac 轮询。
- LAN 路径不维持永久连接；仅在有待发事件时进行有界 NSD 和短连接。
- Relay 路径由 Android 发起短 HTTPS 请求，支持 Wi-Fi、蜂窝网络和普通 VPN 的默认网络。
- Mac 仅维护一个出站 WSS；断开后使用 1、2、5、10、30、60 秒递增等待，不做高频轮询。
- Android 的通知采集与网络发送只持有有时限的 partial wake lock。HyperOS 仍需允许通知读取、自启动并将电量策略设为“无限制”，否则系统可能冻结监听服务。
- 两端都持久化必要状态。断网时事件保留在有界 outbox，网络变化、新事件或用户手动重试会再次唤醒发送。

## 可靠性

- `eventId` 是跨 LAN/Relay 的统一幂等键。
- Android 只有收到对应通道确认后才删除该通道自己的 outbox 副本。
- VPS 接受事件只表示密文已持久化，不表示 Mac 已展示；Mac ACK 后 VPS 才删除密文。
- Relay 重放、ACK 丢失和 LAN/Relay 竞速都通过 Mac 的共享 `RecentDeliveryStore` 消解。
- 密文默认最多保留 168 小时和 1000 条；LAN/Android outbox 继续使用本地保留上限。

## 安全边界

### LAN Beta

LAN v1 仍为可信局域网内的明文、未认证传输。同网设备可能观察或伪造归一化配送状态。不要把 Mac listener 映射到公网，也不要在公共 Wi-Fi 上依赖该通道的机密性。

### Relay v1

- 客户端强制使用 HTTPS/WSS；不会把 bearer token 发送给重定向目标。
- Android 使用随机 12 字节 nonce 和 AES-256-GCM 加密完整 LAN envelope。
- `channelId/eventId/sequence/sentAt` 作为附加认证数据，篡改会导致 Mac 解密失败。
- VPS 只配置 channel ID 和 bearer token，不保存 E2EE content key。
- Android 使用 Android Keystore 加密保存客户端配置；应用关闭备份。
- macOS 配置保存在 `~/Library/Application Support/MiPopup/relay-config.json`，部署时权限设为 `0600`。代码和日志不得打印 token、content key 或密文明文。

当前是本人设备的手工单通道配对，不等同于完整账号系统。配置文件一旦泄露，持有者可以访问通道并解密事件；应立即轮换 server token 和 content key。

## VPS 边界

- Caddy 是唯一公网入口，负责 TLS 和 WSS 反向代理。
- Relay 服务只监听 Compose 私网的 8787 端口。
- SQLite 仅存尚未被 Mac ACK 的密文。
- 无 Web 管理后台、无原始通知接口、无第三方统计 SDK。
- 健康检查 `/healthz` 不包含用户数据；所有 `/v1/*` 接口都要求 bearer token。

部署和轮换步骤见 `services/relay/README.md`，字节级协议见 `protocol/RELAY_PROTOCOL.md`。

## 暂不实现

- NAT 打洞、STUN、TURN、WebRTC DataChannel
- Tailscale 或 Headscale
- 多用户账号、设备列表和远程撤销 UI
- APNs/FCM 唤醒
- 原始通知或历史 JSONL 云同步
- 自动密钥恢复和多 Mac fan-out 交付语义

## 上游资料

- [Android Network Service Discovery](https://developer.android.com/develop/connectivity/wifi/use-nsd)
- [Android Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)
- [Apple local network privacy TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
