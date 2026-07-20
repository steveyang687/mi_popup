package com.mipopup.capture

import android.content.Context
import java.util.UUID

class LanIdentityStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE
    )

    fun deviceId(): String = synchronized(identityLock) {
        val existing = preferences.getString(KEY_DEVICE_ID, null)
        if (existing != null && LanProtocol.isValidIdentifier(existing)) return existing
        val generated = UUID.randomUUID().toString()
        check(preferences.edit().putString(KEY_DEVICE_ID, generated).commit()) {
            "Unable to persist LAN device identity"
        }
        generated
    }

    fun nextSequence(): Long = synchronized(identityLock) {
        val previous = preferences.getLong(KEY_SEQUENCE, 0L)
        check(previous < Long.MAX_VALUE) { "LAN sequence is exhausted" }
        val next = previous + 1L
        check(preferences.edit().putLong(KEY_SEQUENCE, next).commit()) {
            "Unable to persist LAN sequence"
        }
        next
    }

    companion object {
        private const val PREFERENCES_NAME = "lan_sync_identity"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_SEQUENCE = "sequence"
        private val identityLock = Any()
    }
}

enum class LanSyncPhase {
    STOPPED,
    IDLE,
    DISCOVERING,
    SENDING,
    WAITING_RETRY
}

data class LanSyncSnapshot(
    val phase: LanSyncPhase,
    val pendingCount: Int,
    val message: String,
    val lastAcknowledgedAt: Long?
)

object LanSyncMonitor {
    @Volatile
    private var current = LanSyncSnapshot(
        phase = LanSyncPhase.STOPPED,
        pendingCount = 0,
        message = "局域网同步尚未启动",
        lastAcknowledgedAt = null
    )

    fun snapshot(): LanSyncSnapshot = current

    @Synchronized
    fun update(
        phase: LanSyncPhase,
        pendingCount: Int,
        message: String,
        acknowledgedAt: Long? = current.lastAcknowledgedAt
    ) {
        current = LanSyncSnapshot(phase, pendingCount, message, acknowledgedAt)
    }
}
