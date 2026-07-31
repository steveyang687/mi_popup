package com.mipopup.capture

import org.json.JSONArray
import org.json.JSONObject

/**
 * A user-authored, delivery-shaped notification rule. It deliberately maps only
 * normalized state and ETA to the Mac, never the notification body.
 */
data class CustomDeliveryRule(
    val displayName: String,
    val sourcePackage: String,
    val sourceFormat: CustomDeliverySourceFormat,
    val stage: DeliveryStage,
    val matchAnyTerms: List<String>,
    val contextAnyTerms: List<String>,
    val syncToMac: Boolean
)

enum class CustomDeliverySourceFormat(val wireValue: String) {
    AUTO("auto"),
    STANDARD_NOTIFICATION("standard_notification"),
    HYPEROS_FOCUS("hyperos_focus");

    companion object {
        fun fromWireValue(value: String): CustomDeliverySourceFormat? =
            entries.firstOrNull { it.wireValue == value }
    }
}

object CustomDeliveryRuleCodec {
    fun decode(raw: String): List<CustomDeliveryRule> {
        if (raw.isBlank()) return emptyList()
        val array = JSONArray(raw)
        require(array.length() <= MAX_RULES) { "最多保存 $MAX_RULES 条自定义规则" }
        return List(array.length()) { index -> decodeRule(array.getJSONObject(index), index) }
    }

    fun encode(rules: List<CustomDeliveryRule>): String = JSONArray().apply {
        rules.forEach { rule ->
            put(
                JSONObject()
                    .put("name", rule.displayName)
                    .put("package", rule.sourcePackage)
                    .put("format", rule.sourceFormat.wireValue)
                    .put("stage", rule.stage.wireValue)
                    .put("matchAny", JSONArray(rule.matchAnyTerms))
                    .put("contextAny", JSONArray(rule.contextAnyTerms))
                    .put("syncToMac", rule.syncToMac)
            )
        }
    }.toString(2)

    fun example(): String = encode(
        listOf(
            CustomDeliveryRule(
                displayName = "京东秒送",
                sourcePackage = "com.example.delivery",
                sourceFormat = CustomDeliverySourceFormat.STANDARD_NOTIFICATION,
                stage = DeliveryStage.DELIVERING,
                matchAnyTerms = listOf("骑手正在配送", "配送中"),
                contextAnyTerms = listOf("秒送", "骑手"),
                syncToMac = true
            )
        )
    )

    private fun decodeRule(json: JSONObject, index: Int): CustomDeliveryRule {
        val displayName = requiredString(json, "name", MAX_NAME_LENGTH, index)
        val sourcePackage = requiredString(json, "package", MAX_PACKAGE_LENGTH, index)
        require(PACKAGE_PATTERN.matches(sourcePackage)) { "第 ${index + 1} 条规则的 package 无效" }
        val sourceFormat = CustomDeliverySourceFormat.fromWireValue(
            requiredString(json, "format", 32, index)
        ) ?: error("第 ${index + 1} 条规则的 format 必须是 auto、standard_notification 或 hyperos_focus")
        val stage = DeliveryStage.fromWireValue(requiredString(json, "stage", 48, index))
            ?: error("第 ${index + 1} 条规则的 stage 无效")
        val matchAnyTerms = stringList(json, "matchAny", index, required = true)
        val contextAnyTerms = stringList(json, "contextAny", index, required = false)
        return CustomDeliveryRule(
            displayName = displayName,
            sourcePackage = sourcePackage,
            sourceFormat = sourceFormat,
            stage = stage,
            matchAnyTerms = matchAnyTerms,
            contextAnyTerms = contextAnyTerms,
            syncToMac = json.optBoolean("syncToMac", true)
        )
    }

    private fun requiredString(json: JSONObject, key: String, limit: Int, index: Int): String {
        val value = json.optString(key).trim()
        require(value.isNotEmpty() && value.length <= limit && value.none(Char::isISOControl)) {
            "第 ${index + 1} 条规则的 $key 无效"
        }
        return value
    }

    private fun stringList(
        json: JSONObject,
        key: String,
        index: Int,
        required: Boolean
    ): List<String> {
        val values = json.optJSONArray(key) ?: if (required) {
            error("第 ${index + 1} 条规则缺少 $key")
        } else {
            return emptyList()
        }
        require(values.length() in (if (required) 1 else 0)..MAX_TERMS) {
            "第 ${index + 1} 条规则的 $key 数量无效"
        }
        return List(values.length()) { termIndex ->
            values.optString(termIndex).trim().also { value ->
                require(value.isNotEmpty() && value.length <= MAX_TERM_LENGTH && value.none(Char::isISOControl)) {
                    "第 ${index + 1} 条规则的 $key 包含无效关键词"
                }
            }
        }.distinct()
    }

    private const val MAX_RULES = 32
    private const val MAX_NAME_LENGTH = 48
    private const val MAX_PACKAGE_LENGTH = 200
    private const val MAX_TERMS = 32
    private const val MAX_TERM_LENGTH = 64
    private val PACKAGE_PATTERN = Regex("""[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+""")
}
