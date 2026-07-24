package com.mipopup.capture

enum class RelaySyncPhase {
    STOPPED,
    IDLE,
    SENDING,
    WAITING_RETRY
}

data class RelaySyncSnapshot(
    val phase: RelaySyncPhase,
    val pendingCount: Int,
    val message: String,
    val lastAcknowledgedAt: Long?
)

object RelaySyncMonitor {
    @Volatile
    private var current = RelaySyncSnapshot(
        phase = RelaySyncPhase.STOPPED,
        pendingCount = 0,
        message = "公网中继尚未配置",
        lastAcknowledgedAt = null
    )

    fun snapshot(): RelaySyncSnapshot = current

    @Synchronized
    fun update(
        phase: RelaySyncPhase,
        pendingCount: Int,
        message: String,
        acknowledgedAt: Long? = current.lastAcknowledgedAt
    ) {
        current = RelaySyncSnapshot(phase, pendingCount, message, acknowledgedAt)
    }
}
