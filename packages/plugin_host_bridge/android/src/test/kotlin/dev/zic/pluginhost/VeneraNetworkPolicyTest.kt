package dev.zic.pluginhost

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.json.JSONObject
import org.junit.Test

class VeneraNetworkPolicyTest {
    @Test
    fun advertisesOnlyEncodingsTheRuntimeActuallyDecodes() {
        assertEquals("gzip, deflate", normalizeVeneraAcceptEncoding(null))
        assertEquals(
            "gzip, deflate",
            normalizeVeneraAcceptEncoding("gzip, deflate, br, zstd"),
        )
        assertEquals("gzip", normalizeVeneraAcceptEncoding("x-gzip, br"))
    }

    @Test
    fun dnsFallbackRejectsLoopbackAndPrivateAnswers() {
        assertFalse(isSafeVeneraPublicAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))))
        assertFalse(isSafeVeneraPublicAddress(InetAddress.getByAddress(byteArrayOf(10, 0, 0, 1))))
        assertTrue(
            isSafeVeneraPublicAddress(
                InetAddress.getByAddress(byteArrayOf(1, 1, 1, 1)),
            ),
        )
    }

    @Test
    fun dnsJsonAcceptsOnlyPublicAddressRecords() {
        val payload = JSONObject()
            .put(
                "Answer",
                org.json.JSONArray()
                    .put(JSONObject().put("type", 5).put("data", "alias.example"))
                    .put(JSONObject().put("type", 1).put("data", "127.0.0.1"))
                    .put(JSONObject().put("type", 1).put("data", "1.1.1.1"))
                    .put(JSONObject().put("type", 28).put("data", "2606:4700:4700::1111")),
            )
        assertEquals(
            setOf("1.1.1.1", "2606:4700:4700:0:0:0:0:1111"),
            parseVeneraDnsJson(payload.toString()).map { it.hostAddress }.toSet(),
        )
    }
}
