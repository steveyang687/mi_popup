package com.mipopup.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DeliveryNotificationParserTest {
    @Test
    fun parsesObservedMeituanOngoingNotification() {
        val update = DeliveryNotificationParser.parse(
            input(
                sourcePackage = "com.sankuai.meituan",
                title = "您的外卖订单正在进行中",
                text = "您可前往订单详情页查看具体进展"
            )
        )

        assertEquals(DeliveryProvider.MEITUAN, update?.provider)
        assertEquals(DeliveryStage.UNKNOWN, update?.stage)
        assertEquals(0.95, update?.confidence ?: 0.0, 0.001)
    }

    @Test
    fun parsesDeliveryStageAndEta() {
        val update = DeliveryNotificationParser.parse(
            input(
                sourcePackage = "com.sankuai.meituan.takeoutnew",
                title = "骑手已取餐，正在配送",
                text = "预计 18:35 送达"
            )
        )

        assertEquals(DeliveryStage.DELIVERING, update?.stage)
        assertEquals("18:35", update?.etaText)
    }

    @Test
    fun ignoresObservedFinancialInsuranceMarketingAndParcelNotifications() {
        val negativeSamples = listOf(
            input(title = "【美团月付】剩余额度更新", text = "成功支付后查看剩余额度"),
            input(title = "您的准时宝和放心吃已生效", text = "如配送超时可获得赔付"),
            input(sourcePackage = "me.ele", title = "高温免下厨", text = "领红包，马上下单"),
            input(sourcePackage = "com.taobao.taobao", title = "您的宝贝已发货", text = "点击查看物流进度")
        )

        negativeSamples.forEach { sample ->
            assertNull(DeliveryNotificationParser.parse(sample))
        }
    }

    @Test
    fun ignoresRemovedAndGroupSummaryEvents() {
        assertNull(
            DeliveryNotificationParser.parse(
                input(eventKind = "removed", title = "您的外卖订单正在进行中")
            )
        )
        assertNull(
            DeliveryNotificationParser.parse(
                input(title = "新消息 GroupSummary", text = "你有一条新消息", groupSummary = true)
            )
        )
    }

    @Test
    fun requiresFoodContextForUnobservedGenericStages() {
        assertNull(
            DeliveryNotificationParser.parse(
                input(title = "订单已取消", text = "点击查看详情")
            )
        )
    }

    private fun input(
        eventKind: String = "posted",
        sourcePackage: String = "com.sankuai.meituan",
        title: String = "",
        text: String = "",
        groupSummary: Boolean = false
    ) = DeliveryNotificationInput(
        eventId = "event-1",
        eventKind = eventKind,
        capturedAt = 1,
        sourcePackage = sourcePackage,
        notificationKeyHash = "notification-hash",
        title = title,
        text = text,
        bigText = "",
        subText = "",
        textLines = emptyList(),
        groupSummary = groupSummary
    )
}
