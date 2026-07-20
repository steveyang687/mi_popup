package com.mipopup.capture

import org.json.JSONObject

enum class DeliveryProvider(val wireValue: String, val displayName: String) {
    MEITUAN("meituan", "美团"),
    TAOBAO_INSTANT("taobao_instant", "淘宝闪购")
}

enum class DeliveryStage(val wireValue: String, val displayName: String) {
    ORDER_PLACED("order_placed", "订单已提交"),
    MERCHANT_CONFIRMED("merchant_confirmed", "商家已接单"),
    PREPARING("preparing", "商家备餐中"),
    COURIER_ASSIGNED("courier_assigned", "骑手已接单"),
    COURIER_PICKING_UP("courier_picking_up", "骑手取货中"),
    DELIVERING("delivering", "配送中"),
    ARRIVING("arriving", "即将送达"),
    DELIVERED("delivered", "已送达"),
    CANCELLED("cancelled", "已取消"),
    UNKNOWN("unknown", "订单进行中")
}

data class DeliveryNotificationInput(
    val eventId: String,
    val eventKind: String,
    val capturedAt: Long,
    val sourcePackage: String,
    val notificationKeyHash: String,
    val title: String,
    val text: String,
    val bigText: String,
    val subText: String,
    val textLines: List<String>,
    val groupSummary: Boolean
)

data class DeliveryUpdate(
    val schemaVersion: Int = 1,
    val parserVersion: Int = 1,
    val eventId: String,
    val sourceEventKind: String,
    val capturedAt: Long,
    val provider: DeliveryProvider,
    val stage: DeliveryStage,
    val statusText: String,
    val etaText: String?,
    val confidence: Double,
    val orderKey: String,
    val sourcePackage: String
) {
    fun toJson(): JSONObject = JSONObject()
        .put("schemaVersion", schemaVersion)
        .put("parserVersion", parserVersion)
        .put("eventId", eventId)
        .put("sourceEventKind", sourceEventKind)
        .put("capturedAt", capturedAt)
        .put("provider", provider.wireValue)
        .put("state", stage.wireValue)
        .put("statusText", statusText)
        .put("confidence", confidence)
        .put("orderKey", orderKey)
        .put("sourcePackage", sourcePackage)
        .also { json -> etaText?.let { json.put("etaText", it) } }
}

object DeliveryNotificationParser {
    fun parse(input: DeliveryNotificationInput): DeliveryUpdate? {
        if (input.eventKind == "removed" || input.groupSummary) return null

        val provider = providerFor(input.sourcePackage) ?: return null
        val fields = listOf(input.title, input.text, input.bigText, input.subText) + input.textLines
        val normalizedFields = fields.map(::normalize).filter(String::isNotBlank)
        val content = normalizedFields.joinToString(" ")

        if (content.contains("GroupSummary", ignoreCase = true)) return null
        if (EXCLUDED_TERMS.any(content::contains)) return null
        if (provider == DeliveryProvider.TAOBAO_INSTANT &&
            input.sourcePackage == "com.taobao.taobao" &&
            PARCEL_TERMS.any(content::contains)
        ) {
            return null
        }

        val stage = stageFor(content) ?: return null
        if (stage != DeliveryStage.UNKNOWN && !DELIVERY_CONTEXT_TERMS.any(content::contains)) {
            return null
        }
        return DeliveryUpdate(
            eventId = input.eventId,
            sourceEventKind = input.eventKind,
            capturedAt = input.capturedAt,
            provider = provider,
            stage = stage,
            statusText = stage.displayName,
            etaText = extractEta(content),
            confidence = if (stage == DeliveryStage.UNKNOWN) 0.95 else 0.85,
            orderKey = input.notificationKeyHash,
            sourcePackage = input.sourcePackage
        )
    }

    private fun providerFor(packageName: String): DeliveryProvider? = when (packageName) {
        "com.sankuai.meituan", "com.sankuai.meituan.takeoutnew" -> DeliveryProvider.MEITUAN
        "me.ele", "com.taobao.taobao" -> DeliveryProvider.TAOBAO_INSTANT
        else -> null
    }

    private fun stageFor(content: String): DeliveryStage? {
        STAGE_RULES.forEach { (stage, terms) ->
            if (terms.any(content::contains)) return stage
        }
        return null
    }

    private fun extractEta(content: String): String? {
        ETA_PATTERNS.forEach { pattern ->
            val match = pattern.find(content) ?: return@forEach
            return match.groupValues[1]
                .replace('：', ':')
                .replace(Regex("""\s+"""), " ")
                .trim()
        }
        return null
    }

    private fun normalize(value: String): String =
        value.replace(Regex("""\s+"""), " ").trim()

    private val EXCLUDED_TERMS = listOf(
        "月付",
        "额度",
        "账单",
        "还款",
        "红包",
        "优惠券",
        "马上下单",
        "准时宝",
        "放心吃"
    )

    private val PARCEL_TERMS = listOf(
        "宝贝",
        "快递",
        "物流进度",
        "已发货",
        "在途"
    )

    // Only UNKNOWN is confirmed by the current fixture. Specific stages also require
    // explicit food-delivery context until real notifications cover those transitions.
    private val STAGE_RULES = listOf(
        DeliveryStage.CANCELLED to listOf("订单已取消", "订单取消", "已取消"),
        DeliveryStage.DELIVERED to listOf("已送达", "配送完成", "订单已完成"),
        DeliveryStage.ARRIVING to listOf("即将送达", "即将到达", "马上送达", "快到了"),
        DeliveryStage.DELIVERING to listOf("骑手已取餐", "骑手已取货", "正在配送", "配送中", "送餐中", "正在送往"),
        DeliveryStage.COURIER_PICKING_UP to listOf("取货中", "取餐中", "骑手已到店", "骑手到店", "前往商家", "赶往商家"),
        DeliveryStage.COURIER_ASSIGNED to listOf("骑手已接单", "骑手接单", "已分配骑手"),
        DeliveryStage.PREPARING to listOf("正在备餐", "商家备餐", "正在制作", "商家制作"),
        DeliveryStage.MERCHANT_CONFIRMED to listOf("商家已接单", "商家确认订单"),
        DeliveryStage.ORDER_PLACED to listOf("下单成功", "订单已提交"),
        DeliveryStage.UNKNOWN to listOf("外卖订单正在进行中", "外卖订单进行中")
    )

    private val DELIVERY_CONTEXT_TERMS = listOf(
        "外卖",
        "骑手",
        "送餐",
        "备餐",
        "取餐",
        "商家"
    )

    private val ETA_PATTERNS = listOf(
        Regex("""(?:预计|约|大约)\s*(\d{1,2}[:：]\d{2})\s*(?:送达|到达)?"""),
        Regex("""(\d{1,2}[:：]\d{2})\s*(?:送达|到达)"""),
        Regex("""(?:预计|还有|约)\s*(\d{1,3}\s*分钟)\s*(?:送达|到达)?""")
    )
}
