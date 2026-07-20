import Foundation
import Testing
@testable import MiPopupCore

struct DeliveryNotificationParserTests {
    @Test
    func parsesObservedMeituanOngoingNotification() {
        let update = DeliveryNotificationParser.parse(
            notification(
                sourcePackage: "com.sankuai.meituan",
                title: "您的外卖订单正在进行中",
                text: "您可前往订单详情页查看具体进展"
            )
        )

        #expect(update?.provider == .meituan)
        #expect(update?.stage == .unknown)
        #expect(update?.confidence == 0.95)
    }

    @Test
    func parsesDeliveryStageAndETA() {
        let update = DeliveryNotificationParser.parse(
            notification(
                sourcePackage: "com.sankuai.meituan.takeoutnew",
                title: "骑手已取餐，正在配送",
                text: "预计 18:35 送达"
            )
        )

        #expect(update?.stage == .delivering)
        #expect(update?.etaText == "18:35")
    }

    @Test
    func ignoresObservedNonDeliveryNotifications() {
        let samples = [
            notification(title: "【美团月付】剩余额度更新", text: "成功支付后查看剩余额度"),
            notification(title: "您的准时宝和放心吃已生效", text: "如配送超时可获得赔付"),
            notification(sourcePackage: "me.ele", title: "高温免下厨", text: "领红包，马上下单"),
            notification(sourcePackage: "com.taobao.taobao", title: "您的宝贝已发货", text: "点击查看物流进度"),
        ]

        #expect(samples.allSatisfy { DeliveryNotificationParser.parse($0) == nil })
    }

    @Test
    func ignoresRemovedAndGroupSummaryEvents() {
        #expect(
            DeliveryNotificationParser.parse(
                notification(eventKind: "removed", title: "您的外卖订单正在进行中")
            ) == nil
        )
        #expect(
            DeliveryNotificationParser.parse(
                notification(
                    title: "新消息 GroupSummary",
                    text: "你有一条新消息",
                    groupSummary: true
                )
            ) == nil
        )
    }

    @Test
    func requiresFoodContextForUnobservedGenericStages() {
        #expect(
            DeliveryNotificationParser.parse(
                notification(title: "订单已取消", text: "点击查看详情")
            ) == nil
        )
    }

    @Test
    func decodesAndroidDeliveryWirePayload() throws {
        let json = """
        {
          "schemaVersion": 1,
          "eventId": "event-1",
          "eventKind": "posted",
          "capturedAt": 2,
          "postedAt": 1,
          "sourcePackage": "com.sankuai.meituan",
          "appName": "美团",
          "notificationKeyHash": "notification-hash",
          "delivery": {
            "schemaVersion": 1,
            "parserVersion": 1,
            "eventId": "event-1",
            "sourceEventKind": "posted",
            "capturedAt": 2,
            "provider": "meituan",
            "state": "unknown",
            "statusText": "订单进行中",
            "confidence": 0.95,
            "orderKey": "notification-hash",
            "sourcePackage": "com.sankuai.meituan"
          }
        }
        """

        let event = try JSONDecoder().decode(CapturedNotification.self, from: Data(json.utf8))
        #expect(event.delivery?.provider == .meituan)
        #expect(event.delivery?.stage == .unknown)
    }

    private func notification(
        eventKind: String = "posted",
        sourcePackage: String = "com.sankuai.meituan",
        title: String = "",
        text: String = "",
        groupSummary: Bool = false
    ) -> CapturedNotification {
        CapturedNotification(
            schemaVersion: 1,
            eventId: "event-1",
            eventKind: eventKind,
            capturedAt: 1,
            postedAt: 1,
            sourcePackage: sourcePackage,
            appName: sourcePackage,
            notificationKeyHash: "notification-hash",
            title: title,
            text: text,
            groupSummary: groupSummary
        )
    }
}
