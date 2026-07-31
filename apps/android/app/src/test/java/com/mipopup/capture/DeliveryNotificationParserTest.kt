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
        assertEquals(DeliverySourceFormat.STANDARD_NOTIFICATION, update?.sourceFormat)
    }

    @Test
    fun parsesTaobaoInstantDeliveryTimeRangeWithKnightWording() {
        val update = DeliveryNotificationParser.parse(
            input(
                sourcePackage = "com.taobao.taobao",
                title = "预计11:25-11:45送达",
                text = "骑士正在配送"
            )
        )

        assertEquals(DeliveryProvider.TAOBAO_INSTANT, update?.provider)
        assertEquals(DeliveryStage.DELIVERING, update?.stage)
        assertEquals("11:25-11:45", update?.etaText)
    }

    @Test
    fun parsesTaobaoInstantLockerDeliveryAsDelivered() {
        val update = DeliveryNotificationParser.parse(
            input(
                sourcePackage = "com.taobao.taobao",
                title = "订单已存入智能柜",
                text = "您的佬街佬味·手撕鸡订单已存入智能柜，请尽快取货"
            )
        )

        assertEquals(DeliveryProvider.TAOBAO_INSTANT, update?.provider)
        assertEquals(DeliveryStage.DELIVERED, update?.stage)
    }

    @Test
    fun parsesHyperOSFocusStatusEtaAndProgress() {
        val focusParam = """
            {
              "param_v2": {
                "business": "food_delivery",
                "orderId": "1234567890123456",
                "ticker": "15分钟送达",
                "baseInfo": {
                  "title": "预计17分钟后送达",
                  "content": "溪雨观酸菜鱼（樱花路店）"
                },
                "hintInfo": {
                  "title": "尊敬的黑金会员，骑手正在为您送货"
                },
                "progressInfo": {
                  "current": 45,
                  "max": 100
                }
              }
            }
        """.trimIndent()

        val update = DeliveryNotificationParser.parse(
            input(
                title = "您的外卖订单正在进行中",
                text = "您可前往订单详情页查看具体进展",
                focusParam = focusParam
            )
        )

        assertEquals(DeliveryStage.DELIVERING, update?.stage)
        assertEquals("17分钟", update?.etaText)
        assertEquals("尊敬的黑金会员，骑手正在为您送货", update?.statusDetail)
        assertEquals(45, update?.progressPercent)
        assertEquals(DeliverySourceFormat.HYPEROS_FOCUS, update?.sourceFormat)
        assertEquals(0.98, update?.confidence ?: 0.0, 0.001)
    }

    @Test
    fun parsesHyperOSFocusTimeRangeAndPickupStage() {
        val update = DeliveryNotificationParser.parse(
            input(
                title = "您的外卖订单正在进行中",
                focusParam = """
                    {"param_v2":{"baseInfo":{"title":"预计11:30-11:50送达"},
                    "hintInfo":{"title":"商家已出餐，骑手正赶往商家"}}}
                """.trimIndent()
            )
        )

        assertEquals(DeliveryStage.COURIER_PICKING_UP, update?.stage)
        assertEquals("11:30-11:50", update?.etaText)
        assertEquals("商家已出餐，骑手正赶往商家", update?.statusDetail)
    }

    @Test
    fun fallsBackToStandardNotificationWhenFocusPayloadIsInvalid() {
        val update = DeliveryNotificationParser.parse(
            input(
                title = "骑手已取餐，正在配送",
                text = "预计 18:35 送达",
                focusParam = "not-json"
            )
        )

        assertEquals(DeliveryStage.DELIVERING, update?.stage)
        assertEquals(DeliverySourceFormat.STANDARD_NOTIFICATION, update?.sourceFormat)
    }

    @Test
    fun ignoresNonDeliveryHyperOSFocusPayload() {
        assertNull(
            DeliveryNotificationParser.parse(
                input(
                    title = "行程正在进行中",
                    focusParam = """{"param_v2":{"ticker":"即将到达上车点"}}"""
                )
            )
        )
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

    @Test
    fun parsesUserConfiguredStandardNotificationAndKeepsItsSyncChoice() {
        val rule = CustomDeliveryRule(
            displayName = "京东秒送",
            sourcePackage = "com.example.delivery",
            sourceFormat = CustomDeliverySourceFormat.STANDARD_NOTIFICATION,
            stage = DeliveryStage.DELIVERING,
            matchAnyTerms = listOf("配送员正在赶来", "配送中"),
            contextAnyTerms = listOf("秒送", "配送员"),
            syncToMac = false
        )

        val parsed = DeliveryNotificationParser.parseConfigured(
            input(
                sourcePackage = "com.example.delivery",
                title = "京东秒送",
                text = "配送员正在赶来，预计 18:35 送达"
            ),
            listOf(rule)
        )

        assertEquals(DeliveryProvider.CUSTOM, parsed?.update?.provider)
        assertEquals("京东秒送", parsed?.update?.providerName)
        assertEquals(DeliveryStage.DELIVERING, parsed?.update?.stage)
        assertEquals("18:35", parsed?.update?.etaText)
        assertEquals(DeliverySourceFormat.STANDARD_NOTIFICATION, parsed?.update?.sourceFormat)
        assertEquals(false, parsed?.syncToMac)
    }

    @Test
    fun parsesUserConfiguredHyperOSFocusNotification() {
        val rule = CustomDeliveryRule(
            displayName = "自定义外卖",
            sourcePackage = "com.example.delivery",
            sourceFormat = CustomDeliverySourceFormat.HYPEROS_FOCUS,
            stage = DeliveryStage.ARRIVING,
            matchAnyTerms = listOf("马上到"),
            contextAnyTerms = emptyList(),
            syncToMac = true
        )

        val parsed = DeliveryNotificationParser.parseConfigured(
            input(
                sourcePackage = "com.example.delivery",
                focusParam = """{"param_v2":{"ticker":"骑手马上到，预计12分钟送达"}}"""
            ),
            listOf(rule)
        )

        assertEquals(DeliveryStage.ARRIVING, parsed?.update?.stage)
        assertEquals("12分钟", parsed?.update?.etaText)
        assertEquals(DeliverySourceFormat.HYPEROS_FOCUS, parsed?.update?.sourceFormat)
        assertEquals(true, parsed?.syncToMac)
    }

    @Test
    fun customRuleCodecRoundTripsAndRejectsAnInvalidPackage() {
        val rule = CustomDeliveryRule(
            displayName = "测试来源",
            sourcePackage = "com.example.delivery",
            sourceFormat = CustomDeliverySourceFormat.AUTO,
            stage = DeliveryStage.DELIVERED,
            matchAnyTerms = listOf("已送达"),
            contextAnyTerms = emptyList(),
            syncToMac = true
        )

        assertEquals(listOf(rule), CustomDeliveryRuleCodec.decode(CustomDeliveryRuleCodec.encode(listOf(rule))))
        try {
            CustomDeliveryRuleCodec.decode(
                """[{"name":"测试","package":"not a package","format":"auto","stage":"delivered","matchAny":["已送达"]}]"""
            )
            throw AssertionError("expected invalid package to fail")
        } catch (_: IllegalArgumentException) {
            // Expected: malformed packages must not become notification sources.
        }
    }

    @Test
    fun createsProtocolCompatibleNetworkSyncTestMessage() {
        val update = DeliveryUpdate.networkSyncTest(
            eventId = "11111111-1111-4111-8111-111111111111",
            capturedAt = 42,
            orderKey = "network-test-order-key",
            sourcePackage = "com.mipopup.capture"
        )
        val json = update.toJson()

        assertEquals("posted", update.sourceEventKind)
        assertEquals(DeliveryProvider.CUSTOM, update.provider)
        assertEquals("MiPopup 测试", update.providerName)
        assertEquals(DeliveryStage.DELIVERING, update.stage)
        assertEquals("15 分钟", update.etaText)
        assertEquals(50, update.progressPercent)
        assertEquals("custom", json.getString("provider"))
        assertEquals("standard_notification", json.getString("sourceFormat"))
    }

    private fun input(
        eventKind: String = "posted",
        sourcePackage: String = "com.sankuai.meituan",
        title: String = "",
        text: String = "",
        groupSummary: Boolean = false,
        focusParam: String? = null
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
        groupSummary = groupSummary,
        focusParam = focusParam
    )
}
