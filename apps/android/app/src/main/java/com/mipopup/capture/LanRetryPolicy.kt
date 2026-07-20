package com.mipopup.capture

object LanRetryPolicy {
    private val delaysMillis = longArrayOf(
        10_000L,
        30_000L,
        120_000L,
        600_000L
    )

    fun delayAfterFailure(failureCount: Int): Long? {
        if (failureCount < 0 || failureCount >= delaysMillis.size) return null
        return delaysMillis[failureCount]
    }
}
