package com.mipopup.capture

import android.content.Context
import java.util.Base64

object BundledRelayConfiguration {
    fun installIfNeeded(context: Context): Boolean {
        if (!BuildConfig.USER_FACING) return false
        val encoded = BuildConfig.EMBEDDED_RELAY_CONFIG_BASE64
        require(encoded.isNotEmpty()) { "User build is missing its bundled relay configuration" }
        val json = Base64.getDecoder().decode(encoded).toString(Charsets.UTF_8)
        val bundled = RelayProtocol.parseConfiguration(json)
        val settings = RelaySettings(context.applicationContext)
        if (settings.load() == bundled) return false
        settings.save(bundled)
        return true
    }
}
