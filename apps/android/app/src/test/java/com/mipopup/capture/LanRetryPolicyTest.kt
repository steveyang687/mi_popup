package com.mipopup.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LanRetryPolicyTest {
    @Test
    fun retriesFourTimesWithBoundedBackoff() {
        assertEquals(10_000L, LanRetryPolicy.delayAfterFailure(0))
        assertEquals(30_000L, LanRetryPolicy.delayAfterFailure(1))
        assertEquals(120_000L, LanRetryPolicy.delayAfterFailure(2))
        assertEquals(600_000L, LanRetryPolicy.delayAfterFailure(3))
        assertNull(LanRetryPolicy.delayAfterFailure(4))
        assertNull(LanRetryPolicy.delayAfterFailure(-1))
    }
}
