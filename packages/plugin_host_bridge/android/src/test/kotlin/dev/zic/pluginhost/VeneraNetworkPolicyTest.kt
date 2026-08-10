package dev.zic.pluginhost

import org.junit.Assert.assertEquals
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
    fun appendsBrowserCookiesToSourceProvidedCookieHeaders() {
        assertEquals(
            "nw=1; ipb_member_id=member",
            mergeVeneraCookieHeaders("nw=1", "ipb_member_id=member"),
        )
        assertEquals("nw=1", mergeVeneraCookieHeaders("nw=1", null))
        assertEquals("ipb_member_id=member", mergeVeneraCookieHeaders(null, "ipb_member_id=member"))
        assertEquals(null, mergeVeneraCookieHeaders(" ", " "))
    }

}
