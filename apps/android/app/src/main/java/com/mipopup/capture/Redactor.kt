package com.mipopup.capture

import org.json.JSONArray
import org.json.JSONObject

object Redactor {
    private val phone = Regex("(?<!\\d)1[3-9]\\d{9}(?!\\d)")
    private val longIdentifier = Regex("(?<!\\d)\\d{8,}(?!\\d)")
    private val credential = Regex(
        "(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|token|cookie|authorization|bearer|password|passwd|pwd|secret)(\\s*[:=]\\s*)[^\\s,;]+"
    )

    fun redactText(value: String): String = value
        .replace(phone, "[手机号]")
        .replace(longIdentifier, "[长编号]")
        .replace(credential) { match -> "${match.groupValues[1]}${match.groupValues[2]}[凭据]" }

    fun redact(record: JSONObject): JSONObject {
        val result = JSONObject(record.toString())
        TEXT_FIELDS.forEach { key ->
            if (result.has(key) && !result.isNull(key)) {
                result.put(key, redactText(result.optString(key)))
            }
        }
        val lines = result.optJSONArray("textLines")
        if (lines != null) {
            val redactedLines = JSONArray()
            for (index in 0 until lines.length()) {
                redactedLines.put(redactText(lines.optString(index)))
            }
            result.put("textLines", redactedLines)
        }
        result.optString("focusParam").takeIf(String::isNotBlank)?.let { raw ->
            result.put("focusParam", redactFocusParam(raw))
        }
        return result
    }

    private fun redactFocusParam(raw: String): String {
        val root = runCatching { JSONObject(raw) }.getOrNull()
            ?: return redactText(raw)
        return redactJson(root, parentKey = null).toString()
    }

    private fun redactJson(value: Any?, parentKey: String?): Any? {
        if (parentKey != null && SENSITIVE_FOCUS_KEYS.any(parentKey.lowercase()::contains)) {
            return "[已脱敏]"
        }
        return when (value) {
            is JSONObject -> JSONObject().also { output ->
                value.keys().forEach { key -> output.put(key, redactJson(value.opt(key), key)) }
            }
            is JSONArray -> JSONArray().also { output ->
                for (index in 0 until value.length()) {
                    output.put(redactJson(value.opt(index), parentKey))
                }
            }
            is String -> if (value.startsWith("http://") || value.startsWith("https://")) {
                "[链接]"
            } else {
                redactText(value)
            }
            else -> value
        }
    }

    private val TEXT_FIELDS = listOf("title", "text", "bigText", "subText")
    private val SENSITIVE_FOCUS_KEYS = listOf(
        "authorization",
        "cookie",
        "credential",
        "deeplink",
        "intenturi",
        "latitude",
        "longitude",
        "mobile",
        "orderid",
        "order_id",
        "password",
        "phone",
        "secret",
        "token"
    )
}
