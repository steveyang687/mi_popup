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

    fun matches(packageName: String): Boolean = PackageMatcher.matches(packageName, targetPackages)

    companion object {
        val DEFAULT_PACKAGES = linkedSetOf(
            "com.sankuai.meituan.takeoutnew",
            "com.sankuai.meituan",
            "com.taobao.taobao",
            "me.ele"
        )

        private const val KEY_TARGET_PACKAGES = "target_packages"
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
