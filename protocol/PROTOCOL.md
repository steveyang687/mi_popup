# MiPopup 同局域网同步协议 v1

当前协议只用于同一可信局域网中的 Android 到 macOS 单向状态推送。Android 是连接发起方，Mac 是被动监听方；Mac 只返回 ACK，不轮询 Android，也不发送控制命令。

## TCP 分帧

每条消息由两部分组成：

1. 4 字节无符号大端整数，表示随后 JSON 的 UTF-8 字节数。
2. 一个完整的 UTF-8 JSON 对象，不包含结尾换行。

长度不包含前面的 4 字节。接收方必须先读取完整长度前缀，再读取指定字节数；不允许用 TCP 单次 `read` 的返回边界代替消息边界。首版单帧上限为 16 KiB，长度为 0 或超过上限时立即拒绝该连接。

```text
+----------------------+-------------------------------+
| uint32 length (BE)   | UTF-8 JSON (length bytes)     |
+----------------------+-------------------------------+
```

## Android 到 Mac

Android 发送 `delivery_update` envelope，顶层包含：

- `protocolVersion = 1`
- `type = "delivery_update"`
- 安装级 UUID `deviceId`
- 从 `1` 开始单调递增的正整数 `sequence`
- Unix epoch milliseconds 格式的 `sentAt`
- `DeliveryUpdate` 类型的 `payload`

定义见：

- `schemas/sync-envelope-v1.schema.json`
- `examples/sync-envelope-v1.json`

`payload` 必须满足 `schemas/delivery-update-v1.schema.json`。网络消息不包含原始通知的 `title`、`text`、`bigText`、地址、手机号、完整订单号、通知图片或 `PendingIntent`。

## Mac 到 Android

Mac 完成 envelope 解码、协议版本检查和 `DeliveryUpdate` 校验后返回 ACK，定义见：

- `schemas/sync-ack-v1.schema.json`
- `examples/sync-ack-v1.json`

ACK 的 `eventId` 必须与已接收 `payload.eventId` 相同。首次接受返回 `status = "accepted"`；已处理过同一 `eventId` 时返回 `status = "duplicate"`，两者都表示 Android 可以确认该事件。Android 只有在收到匹配 ACK 后才把该事件视为已送达；连接中断或 ACK 不匹配时按有限退避重试。Mac 应按 `eventId` 去重，因此同一事件重发不会重复触发展示。

## 版本与安全边界

- `protocolVersion` 描述同步 envelope/ACK；当前固定为 `1`。
- `payload.schemaVersion` 描述 `DeliveryUpdate`；当前固定为 `1`。
- 首版没有握手、配对、认证或传输加密，不能降级承载原始通知。
- 该实现只面向本人设备和可信局域网 Beta。处于同一网络的其他设备可能读取状态或伪造消息。
- 公开发布前必须加入显式设备配对、凭据安全存储、加密与完整性校验；在此之前不得宣称端到端加密或安全设备认证。
- 跨网、VPS、中继、NAT 打洞、Tailscale、Headscale、WebRTC 和 TURN 均不属于协议 v1，也没有回退路径。
