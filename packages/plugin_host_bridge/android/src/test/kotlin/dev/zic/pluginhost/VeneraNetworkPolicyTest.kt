package dev.zic.pluginhost

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.json.JSONObject
import org.junit.Test

class VeneraNetworkPolicyTest {
    @Test
    fun textResponseConsumesOnlyTheLeadingUtf8ByteOrderMark() {
        val text = "{\"title\":\"禁漫\uFEFF正文\"}"
        val body = ("\uFEFF" + text).encodeToByteArray()
        val response = VeneraHttpResponse(200, JSONObject(), body)
        val wire = response.toWire(bytes = false)

        assertEquals(text, wire.getString("body"))
        assertEquals(200, wire.getInt("status"))
        assertSame(body, response.body)
        assertArrayEquals(("\uFEFF" + text).encodeToByteArray(), body)
    }

    @Test
    fun textResponseKeepsOrdinaryPrefixesAndASecondByteOrderMark() {
        val cases = mapOf(
            "" to "",
            "中文" to "中文",
            " \uFEFF正文" to " \uFEFF正文",
            "\uFEFF\uFEFF正文" to "\uFEFF正文",
        )
        for ((encoded, expected) in cases) {
            val response = VeneraHttpResponse(
                200, JSONObject(), encoded.encodeToByteArray(),
            )
            assertEquals(expected, response.toWire(bytes = false).getString("body"))
        }
    }

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

    @Test
    fun longResolverCacheSurvivesStoreRecreationButShortCacheDoesNot() {
        val root = temporaryCacheRoot("survive")
        try {
            val namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a")
            val headers = linkedMapOf(
                "Cookie" to "session=a",
                "Authorization" to "Bearer alpha",
            )
            val response = VeneraHttpResponse(
                200,
                JSONObject().put("content-type", "text/html"),
                "resolver".encodeToByteArray(),
            )
            val first = VeneraHttpCacheStore(root)
            first.store(
                namespace,
                "https://fixture/gallery",
                headers,
                response,
                nowNanos = 1_000L,
                cacheTime = "long",
                nowEpochMillis = 1_000_000L,
            )
            first.store(
                namespace,
                "https://fixture/short",
                headers,
                response,
                nowNanos = 1_000L,
                cacheTime = null,
                nowEpochMillis = 1_000_000L,
            )
            first.clearMemory()

            val reopened = VeneraHttpCacheStore(root)
            val durable = reopened.lookup(
                namespace,
                "https://fixture/gallery",
                headers,
                "long",
                nowNanos = 500_001_000L,
                nowEpochMillis = 1_000_500L,
            )
            assertNotNull(durable)
            assertEquals("true", durable!!.headers.getString("venera-cache"))
            assertNull(
                reopened.lookup(
                    namespace,
                    "https://fixture/short",
                    headers,
                    null,
                    nowNanos = 500_001_000L,
                    nowEpochMillis = 1_000_500L,
                ),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun longLookupPromotesAnExistingMemoryResponseIntoTheDurableTier() {
        val root = temporaryCacheRoot("promote")
        try {
            val namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a")
            val headers = linkedMapOf("Cookie" to "session=a")
            val response = VeneraHttpResponse(
                200,
                JSONObject().put("content-type", "text/html"),
                "gallery".encodeToByteArray(),
            )
            val cache = VeneraHttpCacheStore(root)
            cache.store(
                namespace,
                "https://fixture/gallery",
                headers,
                response,
                nowNanos = 1_000L,
                cacheTime = null,
                nowEpochMillis = 1_000_000L,
            )
            assertNotNull(
                cache.lookup(
                    namespace,
                    "https://fixture/gallery",
                    headers,
                    "long",
                    nowNanos = 2_000L,
                    nowEpochMillis = 1_000_001L,
                ),
            )
            cache.clearMemory()
            assertNotNull(
                VeneraHttpCacheStore(root).lookup(
                    namespace,
                    "https://fixture/gallery",
                    headers,
                    "long",
                    nowNanos = 3_000L,
                    nowEpochMillis = 1_000_002L,
                ),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun durableLongCacheRejectsAuthChangesAndExpiredEntries() {
        val root = temporaryCacheRoot("identity")
        try {
            val namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a")
            val headers = linkedMapOf(
                "Cookie" to "session=a",
                "Authorization" to "Bearer alpha",
            )
            val response = VeneraHttpResponse(
                200,
                JSONObject().put("content-type", "text/html"),
                "resolver".encodeToByteArray(),
            )
            VeneraHttpCacheStore(root).store(
                namespace,
                "https://fixture/gallery",
                headers,
                response,
                cacheTime = "long",
                nowEpochMillis = 2_000_000L,
            )
            assertNull(
                VeneraHttpCacheStore(root).lookup(
                    namespace,
                    "https://fixture/gallery",
                    linkedMapOf(
                        "Cookie" to "session=a",
                        "Authorization" to "Bearer beta",
                    ),
                    "long",
                    nowEpochMillis = 2_000_100L,
                ),
            )

            VeneraHttpCacheStore(root).store(
                namespace,
                "https://fixture/gallery",
                headers,
                response,
                cacheTime = "long",
                nowEpochMillis = 3_000_000L,
            )
            assertNull(
                VeneraHttpCacheStore(root).lookup(
                    namespace,
                    "https://fixture/gallery",
                    headers,
                    "long",
                    nowEpochMillis = 3_000_000L + 6L * 60L * 60L * 1_000L + 1L,
                ),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun requestCacheIdentityIncludesAuthorization() {
        assertFalse(
            veneraCacheHeadersMatch(
                mapOf("Authorization" to "Bearer alpha"),
                mapOf("Authorization" to "Bearer beta"),
            ),
        )
    }

    @Test
    fun noStoreResolverResponseNeverBecomesRuntimeCacheAuthority() {
        val cache = VeneraHttpCacheStore()
        val namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a")
        val headers = linkedMapOf("Accept" to "*/*")
        cache.store(
            namespace,
            "https://fixture/chapter",
            headers,
            VeneraHttpResponse(
                200,
                JSONObject().put("content-type", "application/json"),
                "{\"images\":[]}".encodeToByteArray(),
            ),
            500L,
        )
        val response = VeneraHttpResponse(
            200,
            JSONObject()
                .put("content-type", "text/html; charset=UTF-8")
                .put("cache-control", "no-store, no-cache, must-revalidate"),
            "Could not connect to mysql!".encodeToByteArray(),
        )

        cache.store(namespace, "https://fixture/chapter", headers, response, 1_000L)

        assertNull(
            cache.lookup(
                namespace,
                "https://fixture/chapter",
                headers,
                null,
                nowNanos = 2_000L,
            ),
        )
        assertNull(
            cache.staleForRevalidation(
                namespace,
                "https://fixture/chapter",
                headers,
                null,
                nowNanos = 6L * 1_000_000_000L,
            ),
        )
    }

    @Test
    fun defaultResolverCacheExposesOnlyFiveSecondToTwoHourRevalidationWindow() {
        val cache = VeneraHttpCacheStore()
        val namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a")
        val headers = linkedMapOf("Cookie" to "session=a")
        val response = VeneraHttpResponse(
            200,
            JSONObject()
                .put("content-type", "text/html")
                .put("etag", "fixture-v1")
                .put("date", "old-date"),
            "resolver".encodeToByteArray(),
        )
        cache.store(namespace, "https://fixture/gallery", headers, response, 1_000L)

        assertNull(
            cache.staleForRevalidation(
                namespace,
                "https://fixture/gallery",
                headers,
                null,
                nowNanos = 4L * 1_000_000_000L,
            ),
        )
        assertNotNull(
            cache.staleForRevalidation(
                namespace,
                "https://fixture/gallery",
                headers,
                null,
                nowNanos = 6L * 1_000_000_000L,
            ),
        )
        assertNull(
            cache.staleForRevalidation(
                namespace,
                "https://fixture/gallery",
                headers,
                null,
                nowNanos = 2L * 60L * 60L * 1_000_000_000L + 2_000L,
            ),
        )
        assertNull(
            cache.staleForRevalidation(
                namespace,
                "https://fixture/gallery",
                headers,
                "long",
                nowNanos = 6L * 1_000_000_000L,
            ),
        )
    }

    @Test
    fun resolverRevalidationIgnoresVolatileHeadersButRejectsBodyIdentityChanges() {
        val cached = JSONObject()
            .put("content-type", "text/html")
            .put("content-length", "123")
            .put("etag", "fixture-v1")
            .put("date", "old-date")
            .put("cf-ray", "old-ray")
        val unchanged = JSONObject()
            .put("content-type", "text/html")
            .put("content-length", "123")
            .put("etag", "fixture-v1")
            .put("date", "new-date")
            .put("cf-ray", "new-ray")
        val changed = JSONObject(unchanged.toString()).put("etag", "fixture-v2")

        assertTrue(veneraCacheResponseHeadersMatch(cached, unchanged))
        assertFalse(veneraCacheResponseHeadersMatch(cached, changed))
    }

    @Test
    fun resolverHttpFailureKeepsTypedRetryabilityAcrossTheAsyncBridge() {
        val networkFailure = veneraBridgeFailureEnvelope(
            VeneraResolverHttpException(
                resolverCode = "venera-resolver-http-failed",
                retryable = true,
                message = "cannot decrypt peer's message",
            ),
        )
        assertEquals("venera-resolver-http-failed", networkFailure.getString("errorCode"))
        assertTrue(networkFailure.getBoolean("retryable"))
        assertTrue(networkFailure.getString("error").contains("cannot decrypt peer's message"))

        val sourceFailure = veneraBridgeFailureEnvelope(
            IllegalStateException("source script failed"),
        )
        assertFalse(sourceFailure.has("errorCode"))
        assertFalse(sourceFailure.optBoolean("retryable", false))
    }

    @Test
    fun explicitFreshResolverMissInvalidatesOnlyTheTouchedCacheEntry() {
        val cache = VeneraHttpCacheStore()
        val namespace = VeneraHttpCacheNamespace("plugin", "v1", "source-a")
        val headers = linkedMapOf("Cookie" to "session=a")
        val response = VeneraHttpResponse(200, JSONObject(), "resolver".encodeToByteArray())
        cache.store(namespace, "https://fixture/page-a", headers, response, 1_000L)
        cache.store(namespace, "https://fixture/page-b", headers, response, 1_000L)

        assertNull(
            cache.lookup(
                namespace = namespace,
                url = "https://fixture/page-a",
                requestHeaders = headers,
                cacheTime = "long",
                forceMiss = true,
                nowNanos = 2_000L,
            ),
        )
        assertNull(
            cache.lookup(
                namespace,
                "https://fixture/page-a",
                headers,
                "long",
                nowNanos = 2_000L,
            ),
        )
        assertNotNull(
            cache.lookup(
                namespace,
                "https://fixture/page-b",
                headers,
                "long",
                nowNanos = 2_000L,
            ),
        )
    }


    private fun temporaryCacheRoot(label: String): File =
        File(
            System.getProperty("java.io.tmpdir"),
            "zic-venera-cache-$label-${System.nanoTime()}",
        ).apply { mkdirs() }

}
