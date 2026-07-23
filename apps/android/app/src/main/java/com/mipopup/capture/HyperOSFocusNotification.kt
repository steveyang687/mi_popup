package com.mipopup.capture

import org.json.JSONArray
import org.json.JSONObject

data class FocusTextCandidate(
    val path: String,
    val value: String
)

data class HyperOSFocusPayload(
    val textCandidates: List<FocusTextCandidate>,
    val progressPercent: Int?
)

/** Reads Xiaomi HyperOS focus-notification data carried in Notification.extras. */
object HyperOSFocusNotification {
    const val EXTRA_PARAM = "miui.focus.param"
    const val MAX_PARAM_LENGTH = 128 * 1024

    fun parse(rawParam: String?): HyperOSFocusPayload? {
        val raw = rawParam?.trim()?.takeIf(String::isNotEmpty) ?: return null
        if (raw.length > MAX_PARAM_LENGTH) return null
        val root = runCatching { JSONObject(raw) }.getOrNull() ?: return null
        val candidates = mutableListOf<FocusTextCandidate>()
        collectText(root, path = "", depth = 0, output = candidates)
        return HyperOSFocusPayload(
            textCandidates = candidates.distinctBy { it.value },
            progressPercent = findProgress(root, depth = 0)
        )
    }

    private fun collectText(
        value: Any?,
        path: String,
        depth: Int,
        output: MutableList<FocusTextCandidate>
    ) {
        if (depth > MAX_DEPTH || output.size >= MAX_TEXT_CANDIDATES) return
        when (value) {
            is JSONObject -> value.keys().forEach { key ->
                if (output.size >= MAX_TEXT_CANDIDATES) return@forEach
                val childPath = if (path.isEmpty()) key else "$path.$key"
                collectText(value.opt(key), childPath, depth + 1, output)
            }
            is JSONArray -> {
                for (index in 0 until minOf(value.length(), MAX_ARRAY_ITEMS)) {
                    collectText(value.opt(index), "$path[$index]", depth + 1, output)
                }
            }
            is String -> {
                val normalized = value.replace(Regex("""\s+"""), " ").trim()
                if (normalized.isNotEmpty() &&
                    normalized.length <= MAX_TEXT_LENGTH &&
                    isUserFacing(path, normalized)
                ) {
                    output += FocusTextCandidate(path, normalized)
                }
            }
        }
    }

    private fun isUserFacing(path: String, value: String): Boolean {
        val normalizedPath = path.lowercase()
        if (IGNORED_PATH_PARTS.any(normalizedPath::contains)) return false
        if (value.startsWith("http://") || value.startsWith("https://")) return false
        if (value.startsWith("miui.focus.")) return false
        if (value.matches(Regex("""#[0-9a-fA-F]{6,8}"""))) return false
        return value.any { it.isLetter() }
    }

    private fun findProgress(value: Any?, depth: Int): Int? {
        if (depth > MAX_DEPTH) return null
        return when (value) {
            is JSONObject -> {
                directProgress(value) ?: value.keys().asSequence()
                    .mapNotNull { key -> findProgress(value.opt(key), depth + 1) }
                    .firstOrNull()
            }
            is JSONArray -> (0 until minOf(value.length(), MAX_ARRAY_ITEMS)).asSequence()
                .mapNotNull { index -> findProgress(value.opt(index), depth + 1) }
                .firstOrNull()
            else -> null
        }
    }

    private fun directProgress(objectValue: JSONObject): Int? {
        val keys = objectValue.keys().asSequence().toList()
        for (key in keys) {
            val normalized = key.lowercase()
            if (normalized.contains("percent") || normalized.contains("percentage")) {
                numericPercent(objectValue.opt(key))?.let { return it }
            }
        }

        val currentKey = keys.firstOrNull {
            val key = it.lowercase()
            key == "current" || key == "currentvalue" || key == "progress"
        }
        val maximumKey = keys.firstOrNull {
            val key = it.lowercase()
            key == "max" || key == "maximum" || key == "total" || key == "progressmax"
        }
        val current = currentKey?.let { number(objectValue.opt(it)) }
        val maximum = maximumKey?.let { number(objectValue.opt(it)) }
        if (current != null && maximum != null && maximum > 0 && current in 0.0..maximum) {
            return ((current / maximum) * 100).toInt().coerceIn(0, 100)
        }
        return null
    }

    private fun numericPercent(value: Any?): Int? {
        val number = number(value) ?: return null
        return when {
            number in 0.0..100.0 -> number.toInt()
            else -> null
        }
    }

    private fun number(value: Any?): Double? = when (value) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }

    private const val MAX_DEPTH = 12
    private const val MAX_ARRAY_ITEMS = 64
    private const val MAX_TEXT_CANDIDATES = 128
    private const val MAX_TEXT_LENGTH = 512

    private val IGNORED_PATH_PARTS = listOf(
        "action",
        "business",
        "color",
        "orderid",
        "order_id",
        "pic",
        "protocol",
        "sequence",
        "timeout",
        "url"
    )
}
