package com.mipopup.capture

import android.content.Context
import java.util.UUID

class CaptureSettings(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        "capture_settings",
        Context.MODE_PRIVATE
    )

    var targetPackages: Set<String>
        get() = parsePackages(
            preferences.getString(KEY_TARGET_PACKAGES, null)
                ?: DEFAULT_PACKAGES.joinToString("\n")
        )
        set(value) {
            preferences.edit()
                .putString(KEY_TARGET_PACKAGES, value.sorted().joinToString("\n"))
                .apply()
        }

    val keySalt: String
        get() {
            val existing = preferences.getString(KEY_SALT, null)
            if (existing != null) return existing
            val generated = UUID.randomUUID().toString()
            preferences.edit().putString(KEY_SALT, generated).apply()
            return generated
        }

    var customDeliveryRules: List<CustomDeliveryRule>
        get() = runCatching {
            CustomDeliveryRuleCodec.decode(preferences.getString(KEY_CUSTOM_DELIVERY_RULES, "[]").orEmpty())
        }.getOrDefault(emptyList())
        set(value) {
            preferences.edit()
                .putString(KEY_CUSTOM_DELIVERY_RULES, CustomDeliveryRuleCodec.encode(value))
                .apply()
        }

    fun matches(packageName: String): Boolean =
        PackageMatcher.matches(packageName, targetPackages) ||
            customDeliveryRules.any { it.sourcePackage == packageName }

    companion object {
        val DEFAULT_PACKAGES = linkedSetOf(
            "com.sankuai.meituan.takeoutnew",
            "com.sankuai.meituan",
            "com.taobao.taobao",
            "me.ele"
        )

        private const val KEY_TARGET_PACKAGES = "target_packages"
        private const val KEY_CUSTOM_DELIVERY_RULES = "custom_delivery_rules"
        private const val KEY_SALT = "key_salt"

        fun parsePackages(raw: String): Set<String> = raw
            .split(',', ';', '\n')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toSet()
    }
}

object PackageMatcher {
    fun matches(packageName: String, targets: Set<String>): Boolean = packageName in targets
}
