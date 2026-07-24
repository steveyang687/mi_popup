# MiPopup 加密中继协议 v1

中继是 LAN v1 的可选并行传输，不是降级替代。Android 仍优先按通知事件主动推送；Mac 不轮询手机。

## 数据流

```text
Android DeliveryUpdate
  -> LAN envelope JSON
  -> AES-256-GCM(client encryptionKey)
  -> POST https://relay.example.com/v1/events
  -> VPS SQLite（仅密文）
  -> WSS /v1/stream
  -> macOS AES-GCM 认证解密
  -> LAN envelope 校验与共享 eventId 去重
  -> POST /v1/acks
  -> VPS 删除密文
```

所有 `/v1/*` 请求使用 `Authorization: Bearer <token>`。客户端配置包含 `baseURL`、`channelId`、`token` 和 32 字节标准 Base64 `encryptionKey`；服务器只配置前三者中的 `channelId` 和 `token`。

## Relay event

```json
{
  "version": 1,
  "channelId": "channel_xxx",
  "eventId": "01234567-89ab-4cde-8fab-0123456789ab",
  "sequence": 7,
  "sentAt": 1784390000000,
  "nonce": "12-byte-standard-base64",
  "ciphertext": "ciphertext-plus-16-byte-gcm-tag-base64"
}
```

明文是 `sync-envelope-v1` 的完整 UTF-8 JSON。AES-GCM 的附加认证数据为以下 UTF-8 字节，最后没有换行：

```text
mipopup-relay-v1\n<channelId>\n<eventId>\n<sequence>\n<sentAt>
```

VPS 按 `(channelId, eventId)` 幂等写入。Android 收到 `accepted` 或 `duplicate` 后删除 Relay outbox 副本；这不会影响 LAN outbox。

macOS 认证解密后还必须执行 LAN envelope 的全部白名单校验，并确认外层 `eventId/sequence` 与密文内一致。只有进入共享 `RecentDeliveryStore` 后才向 `/v1/acks` 提交：

```json
{"eventId":"01234567-89ab-4cde-8fab-0123456789ab"}
```

ACK 后服务器删除事件。ACK 丢失时服务器可能重放；macOS 必须按 `eventId` 返回幂等结果，不能重复触发展示。

## 边界

- HTTPS/WSS 是强制条件，客户端拒绝明文 HTTP。
- Relay 不传输原始通知、地址、手机号、完整订单号、图片或 `PendingIntent`。
- Bearer token 控制通道访问；AES-GCM content key 保证服务器不能读取或篡改内容。
- 当前为单用户手工配对，不提供账号、密钥恢复、多设备管理、远程撤销 UI 或 Web 控制台。
- 当前不做 NAT 打洞、Tailscale、Headscale、TURN 或 WebRTC。
