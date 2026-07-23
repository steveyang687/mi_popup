package com.mipopup.capture

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RedactorTest {
    @Test
    fun redactsPhoneOrderNumberAndToken() {
        val value = Redactor.redactText(
            "骑手 13812345678，订单 123456789012，token=secret password=hunter2 api_key=sk-test"
        )
        assertEquals("骑手 [手机号]，订单 [长编号]，token=[凭据] password=[凭据] api_key=[凭据]", value)
    }

    @Test
    fun keepsDeliveryTimesAndShortNumbers() {
        assertEquals("预计 18:35 送达，还有 12 分钟", Redactor.redactText("预计 18:35 送达，还有 12 分钟"))
    }

    @Test
    fun redactsSensitiveFocusFieldsButKeepsDeliveryStatus() {
        val record = JSONObject()
            .put("focusParam", """
                {"param_v2":{"orderId":"ABCD1234","token":"secret-value",
                "baseInfo":{"title":"预计17分钟后送达"},
                "hintInfo":{"title":"骑手正在为您送货"}}}
            """.trimIndent())

        val focus = JSONObject(Redactor.redact(record).getString("focusParam"))
            .getJSONObject("param_v2")

        assertEquals("[已脱敏]", focus.getString("orderId"))
        assertEquals("[已脱敏]", focus.getString("token"))
        assertEquals("预计17分钟后送达", focus.getJSONObject("baseInfo").getString("title"))
        assertEquals("骑手正在为您送货", focus.getJSONObject("hintInfo").getString("title"))
    }

    @Test
    fun packageMatcherIsExact() {
        val targets = setOf("com.taobao.taobao")
        assertTrue(PackageMatcher.matches("com.taobao.taobao", targets))
        assertFalse(PackageMatcher.matches("com.taobao.taobao.beta", targets))
    }
}
