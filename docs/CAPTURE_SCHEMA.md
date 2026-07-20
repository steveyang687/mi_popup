# MiPopup Notification Capture Schema v1

文件格式为 UTF-8 JSON Lines：每行一个完整 JSON 对象，不使用外层数组。时间均为 Unix epoch milliseconds。

## 事件类型

- `posted`：本次服务进程中首次看到该通知 key。
- `active`：监听服务连接或用户主动扫描时发现的当前活动通知。
- `updated`：相同通知 key 的可见内容发生变化。
- `removed`：通知从通知栏移除。可能由应用更新、用户清除或系统行为触发，不能直接解释为订单完成。

Android 的通知更新仍会回调 `onNotificationPosted`；采集器使用加盐后的通知 key 和内容哈希区分 `posted`、`updated` 与完全重复回调。

## 字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `schemaVersion` | integer | 当前固定为 `1` |
| `eventId` | string | 每条采集事件的 UUID |
| `eventKind` | string | `posted`、`active`、`updated` 或 `removed`；`active` 表示服务连接后主动扫描到的已有通知 |
| `capturedAt` | integer | 采集器收到回调的时间 |
| `postedAt` | integer | Android `StatusBarNotification.postTime` |
| `sourcePackage` | string | 实际来源包名，是适配器路由的主键 |
| `appName` | string | 系统解析出的应用显示名称 |
| `notificationKeyHash` | string | 使用每次安装随机盐计算的 SHA-256；不导出原始 key |
| `notificationId` | integer | 应用提供的通知 ID，仅作调试辅助 |
| `title` | string | `Notification.EXTRA_TITLE` |
| `text` | string | `Notification.EXTRA_TEXT` |
| `bigText` | string | `Notification.EXTRA_BIG_TEXT` |
| `subText` | string | `Notification.EXTRA_SUB_TEXT` |
| `textLines` | string[] | `Notification.EXTRA_TEXT_LINES` |
| `category` | string | Android 通知 category |
| `channelId` | string | Android 8+ 通知渠道 ID |
| `tickerText` | string | 通知 ticker 文本，部分厂商动态通知会使用 |
| `extrasKeys` | string[] | 通知 extras 的字段名列表，不额外导出未知字段的值 |
| `progress` | integer | 标准通知进度值 |
| `progressMax` | integer | 标准通知进度上限 |
| `progressIndeterminate` | boolean | 是否为不确定进度 |
| `groupKey` | string | Android 通知分组 key |
| `tag` | string | 应用提供的通知 tag |
| `groupSummary` | boolean | 是否为通知分组摘要；采样阶段保留该事件，避免漏掉厂商动态通知 |
| `ongoing` | boolean | 是否为 ongoing 通知 |
| `clearable` | boolean | 用户是否可清除 |
| `delivery` | object? | Android 端确认命中配送规则时写入的最小化解析结果；字段契约见 `protocol/schemas/delivery-update-v1.schema.json` |

`removed` 事件只保证包含基础字段，不保证包含通知文本字段。因此后续解析器应按 `notificationKeyHash` 维护最后一次可见内容，但不能把通知移除直接映射为业务终态。

## 配送解析结果

`delivery` 是可选字段。未命中、营销通知、普通淘宝快递、分组摘要和 `removed` 事件均不写入该字段。它只包含固定状态文案、ETA、置信度、来源包名和不可逆通知 key hash，不重复复制原始通知正文。

当前真实样本只确认了美团“外卖订单正在进行中”，因此映射为：

```json
{
  "schemaVersion": 1,
  "parserVersion": 1,
  "eventId": "3aef2db4-f708-4e2f-988d-233d38a07f91",
  "sourceEventKind": "posted",
  "capturedAt": 1784255778298,
  "provider": "meituan",
  "state": "unknown",
  "statusText": "订单进行中",
  "confidence": 0.95,
  "orderKey": "b73b99bb6bcbb468aca76311d18efd7365c2c15158b60cf2935adc0cc038399d",
  "sourcePackage": "com.sankuai.meituan"
}
```

`unknown` 表示已经确认存在外卖订单，但通知没有提供足够信息判断接单、备餐、取货或配送阶段。淘宝闪购目前只有营销负样本，尚未宣称支持具体配送状态。

## 与同局域网同步的关系

采集 JSONL 和局域网协议是两条不同的数据路径：

- 采集 JSONL 可以包含原始通知标准字段，只保存在 Android 应用私有目录，并且只能由用户主动导出。
- 局域网同步只取事件中的 `delivery` 对象，不发送其余采集字段，也不发送整个 JSONL 行。
- Android 用 `protocol/schemas/sync-envelope-v1.schema.json` 包装一个 `DeliveryUpdate`。
- Mac 接收并校验成功后按 `protocol/schemas/sync-ack-v1.schema.json` 返回 ACK。
- TCP 分帧、重试和当前明文可信局域网 Beta 边界见 `protocol/PROTOCOL.md`。

没有 `delivery` 的事件不会发送到网络。`removed`、完全重复回调、分组摘要、营销通知和未命中解析器的通知仍可用于本地采样，但不会触发 Mac 更新。

## 解析阶段输入要求

后续为美团和淘宝闪购分别实现适配器时，至少需要覆盖以下真实样本：商家接单、备餐、骑手接单、骑手到店、配送中、即将送达、已送达、订单取消，以及同一阶段 ETA/骑手距离更新。提交样本前请人工复核脱敏结果。
