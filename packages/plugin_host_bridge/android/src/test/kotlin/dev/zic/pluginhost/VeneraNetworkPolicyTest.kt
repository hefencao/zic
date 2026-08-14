package dev.zic.pluginhost

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
    fun appendsBrowserCookiesToSourceProvidedCookieHeaders() {
        assertEquals(
            "nw=1; ipb_member_id=member",
            mergeVeneraCookieHeaders("nw=1", "ipb_member_id=member"),
        )
        assertEquals("nw=1", mergeVeneraCookieHeaders("nw=1", null))
        assertEquals("ipb_member_id=member", mergeVeneraCookieHeaders(null, "ipb_member_id=member"))
        assertEquals(null, mergeVeneraCookieHeaders(" ", " "))
    }

    @Test
    fun sharedResolverCacheSurvivesBridgeReplacementWithinSameSourceNamespace() {
        val cache = VeneraHttpCacheStore()
        val headers = linkedMapOf("Cookie" to "session=a", "Accept-Encoding" to "gzip")
        val response = VeneraHttpResponse(
            status = 200,
            headers = JSONObject().put("content-type", "text/html"),
            body = "resolver".encodeToByteArray(),
        )
        cache.store(
            namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a"),
            url = "https://fixture/gallery",
            requestHeaders = headers,
            response = response,
            nowNanos = 1_000L,
        )

        assertNotNull(
            cache.lookup(
                namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a"),
                url = "https://fixture/gallery",
                requestHeaders = headers,
                cacheTime = "long",
                nowNanos = 2_000L,
            ),
        )
        assertNull(
            cache.lookup(
                namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-b"),
                url = "https://fixture/gallery",
                requestHeaders = headers,
                cacheTime = "long",
                nowNanos = 2_000L,
            ),
        )
        assertNull(
            cache.lookup(
                namespace = VeneraHttpCacheNamespace("plugin", "v2", "source-a"),
                url = "https://fixture/gallery",
                requestHeaders = headers,
                cacheTime = "long",
                nowNanos = 2_000L,
            ),
        )
    }

    @Test
    fun sharedResolverCacheStillHonorsRequestIdentityAndHostLifetimeClear() {
        val cache = VeneraHttpCacheStore()
        val headers = linkedMapOf("Cookie" to "session=a")
        val response = VeneraHttpResponse(200, JSONObject(), "resolver".encodeToByteArray())
        cache.store(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/gallery", headers, response, 1_000L)

        assertNull(
            cache.lookup(
                VeneraHttpCacheNamespace("plugin", "v1", "source-a"),
                "https://fixture/gallery",
                linkedMapOf("Cookie" to "session=b"),
                "long",
                2_000L,
            ),
        )
        cache.clear()
        assertNull(
            cache.lookup(
                VeneraHttpCacheNamespace("plugin", "v1", "source-a"),
                "https://fixture/gallery",
                headers,
                "long",
                2_000L,
            ),
        )
    }

}
