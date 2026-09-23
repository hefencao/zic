package dev.zic.pluginhost

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

class MihonHostAbiTest {
    @Test
    fun reportsMissingClassesForTheSelectedLoaderOnly() {
        val missing = setOf("androidx.preference.Preference", "rx.Observable")
        val loader = object : ClassLoader(null) {
            override fun loadClass(name: String): Class<*> {
                if (name in missing) throw ClassNotFoundException(name)
                return String::class.java
            }
        }

        assertEquals(
            emptyList<String>(),
            missingMihonClasses(loader, requiredMihonPluginAbiClasses),
        )
        assertEquals(
            listOf("androidx.preference.Preference", "rx.Observable"),
            missingMihonClasses(loader, requiredMihonCommonRuntimeClasses),
        )
    }

    @Test
    fun mapsEveryAcceptedMetadataAbiToOnePackagedAsset() {
        assertEquals("1.4", mihonAbiAssetVersion("1.4"))
        assertEquals("1.6", mihonAbiAssetVersion("1.5"))
        assertEquals("1.6", mihonAbiAssetVersion("1.6"))
        assertEquals(setOf("1.4", "1.5", "1.6"), supportedMihonExtensionLibs)
    }

    @Test
    fun verifiesKotlinRuntimeUsedByDynamicallyLoadedExtensions() {
        assertTrue(
            requiredMihonCommonRuntimeClasses.contains("kotlin.jvm.internal.Intrinsics"),
        )
        assertTrue(
            requiredMihonCommonRuntimeClasses.contains("kotlinx.serialization.json.Json"),
        )
    }

    @Test
    fun injectsApplicationNetworkAndJsonLikeMihonAppModule() {
        val application = Application()
        val network = Any()
        val json = Any()

        assertEquals(
            listOf(Application::class.java, String::class.java, Int::class.java),
            mihonInjektSingletons(
                application,
                String::class.java,
                network,
                Int::class.java,
                json,
            ).map { it.first },
        )
    }

    @Test
    fun createsInjectedJsonWithMihonUnknownKeyPolicy() {
        val (jsonType, json) = createMihonJson(javaClass.classLoader!!)
        val configuration = jsonType.getMethod("getConfiguration").invoke(json)

        assertEquals("kotlinx.serialization.json.Json", jsonType.name)
        assertEquals(
            true,
            configuration.javaClass
                .getMethod("getIgnoreUnknownKeys")
                .invoke(configuration),
        )
        assertEquals(
            false,
            configuration.javaClass
                .getMethod("getExplicitNulls")
                .invoke(configuration),
        )
    }

    @Test
    fun extensionClassesAreChildFirstButAbiAndCommonLibrariesAreParentFirst() {
        assertFalse(isMihonParentFirstClass("eu.kanade.tachiyomi.extension.all.ehentai.EHFactory"))
        assertFalse(isMihonParentFirstClass("a"))
        assertTrue(isMihonParentFirstClass("eu.kanade.tachiyomi.source.online.HttpSource"))
        assertTrue(isMihonParentFirstClass("eu.kanade.tachiyomi.network.NetworkHelper"))
        assertTrue(isMihonParentFirstClass("uy.kohesive.injekt.InjektKt"))
        assertTrue(isMihonParentFirstClass("dev.mihon.injekt.InjektKt"))
        assertTrue(isMihonParentFirstClass("androidx.preference.Preference"))
        assertTrue(isMihonParentFirstClass("okhttp3.OkHttpClient"))
        assertTrue(isMihonParentFirstClass("dev.zic.network.AndroidCookieJar"))
    }

    @Test
    fun requiresTheTypedVerificationFailureAtTheStableReleaseName() {
        assertTrue(
            requiredMihonCommonRuntimeClasses.contains(
                "dev.zic.network.SourceVerificationRequiredException",
            ),
        )
    }

    @Test
    fun keepsBrowserSnapshotImplementationOutOfTheCommonRuntimeAbi() {
        assertTrue(requiredMihonCommonRuntimeClasses.contains("dev.zic.network.AndroidCookieJar"))
        assertFalse(
            requiredMihonCommonRuntimeClasses.contains(
                "dev.zic.network.AndroidBrowserCookieSession",
            ),
        )
    }

    @Test
    fun parsesResourceBackedMihonEntryMetadataAfterResolution() {
        assertEquals(
            listOf(
                "eu.kanade.tachiyomi.extension.zh.fixture.FirstFactory",
                "eu.kanade.tachiyomi.extension.zh.fixture.SecondFactory",
            ),
            parseMihonEntryClasses(
                "eu.kanade.tachiyomi.extension.zh.fixture",
                ".FirstFactory, .SecondFactory; .FirstFactory",
            ),
        )
        assertTrue(
            runCatching {
                parseMihonEntryClasses(
                    "eu.kanade.tachiyomi.extension.zh.fixture",
                    "not a class",
                )
            }.isFailure,
        )
    }

    @Test
    fun derivesCurrentExtensionAbiFromVersionNameWhenMetadataIsAbsent() {
        assertEquals("1.6", normalizeMihonExtensionLib(null, "1.6.4"))
        assertEquals("1.6", normalizeMihonExtensionLib("", "1.6.4"))
        assertEquals("1.6", normalizeMihonExtensionLib("1.6", "9.9.9"))
        assertEquals("1.6", normalizeMihonExtensionLib("1.6.0", "9.9.9"))
        assertEquals("16", normalizeMihonExtensionLib(16, "9.9.9"))
        assertEquals(null, normalizeMihonExtensionLib(null, "invalid"))
    }

    @Test
    fun defersImageResolutionWhenTheExtensionReturnsOnlyAPageUrl() {
        assertTrue(shouldDeferMihonPageImage(null))
        assertTrue(shouldDeferMihonPageImage(""))
        assertFalse(shouldDeferMihonPageImage("https://cdn.invalid/page.webp"))
    }

    @Test
    fun resourceAuthorityRevisionIsBoundToExactPluginPayload() {
        val lower = "ab".repeat(32)
        val upper = lower.uppercase()
        assertEquals(
            "mihon-runtime-transform-v3:$lower",
            mihonResourceAuthorityRevision(upper),
        )
    }

    @Test
    fun resourceReplayRequiresStableChapterAndPageCoordinates() {
        assertTrue(
            mihonResourceHasReplayCoordinates(
                JSONObject()
                    .put("retryChapterId", "mihon:chapter:fixture")
                    .put("retryPageIndex", 3),
            ),
        )
        assertFalse(
            mihonResourceHasReplayCoordinates(
                JSONObject().put("retryChapterId", "mihon:chapter:fixture"),
            ),
        )
        assertFalse(
            mihonResourceHasReplayCoordinates(
                JSONObject().put("retryPageIndex", 3),
            ),
        )
    }

    @Test
    fun directHostPlanReplayRequiresExplicitMarkerAndStableCoordinates() {
        assertTrue(
            mihonResourceAllowsDirectPlanReplay(
                JSONObject()
                    .put("retryChapterId", "mihon:chapter:fixture")
                    .put("retryPageIndex", 3)
                    .put("directPlanReplay", true),
            ),
        )
        assertFalse(
            mihonResourceAllowsDirectPlanReplay(
                JSONObject()
                    .put("retryChapterId", "mihon:chapter:fixture")
                    .put("retryPageIndex", 3),
            ),
        )
        assertFalse(
            mihonResourceAllowsDirectPlanReplay(
                JSONObject().put("directPlanReplay", true),
            ),
        )
    }

    @Test
    fun replayLoadConsumesFreshRequestAuthorityInsteadOfOpaqueStaleRequest() {
        val key = "mihon:fixture\u0000mihon:resource:stale"
        val stale = JSONObject()
            .put("url", "https://old.invalid/page")
            .put("method", "GET")
        val fresh = JSONObject()
            .put("url", "https://fresh.invalid/page")
            .put("method", "POST")
            .put(
                "headers",
                JSONObject()
                    .put("X-Generation", "fresh")
                    .put("Content-Type", "application/octet-stream"),
            )
            .put("bodyBase64", "BwgJ")
        val pending = mutableMapOf(key to fresh)

        val selected = selectMihonResourceForLoad(
            key,
            pending,
            emptyMap(),
        ) { stale }
        assertEquals("BwgJ", selected.getString("bodyBase64"))
        val requestWithoutBody = JSONObject(selected.toString()).apply {
            remove("bodyBase64")
        }
        val request = mihonSerializedRequestFromResource(
            requestWithoutBody,
            mapOf("X-Fallback" to "stale"),
        )

        assertEquals("https://fresh.invalid/page", request.url)
        assertEquals("POST", request.method)
        assertEquals("fresh", request.headers["X-Generation"])
        assertFalse(request.headers.containsKey("X-Fallback"))
        assertEquals(null, request.body)
        assertFalse(pending.containsKey(key))
        assertEquals(
            "https://old.invalid/page",
            selectMihonResourceForLoad(key, pending, emptyMap()) { stale }
                .getString("url"),
        )
    }

    @Test
    fun freshGenerationRequestAuthorityPersistsForResolveAndRuntimeLoad() {
        val key = "mihon:fixture\u0000mihon:resource:stale"
        val stale = JSONObject().put("url", "https://old.invalid/page")
        val fresh = JSONObject()
            .put("url", "https://fresh.invalid/page?token=2")
            .put("method", "GET")
            .put("headers", JSONObject().put("X-Generation", "2"))
        val retained = mapOf(key to fresh)

        repeat(2) {
            val selected = selectMihonResourceForLoad(
                key,
                mutableMapOf(),
                retained,
            ) { stale }
            val request = mihonSerializedRequestFromResource(selected, emptyMap())
            assertEquals("https://fresh.invalid/page?token=2", request.url)
            assertEquals("2", request.headers["X-Generation"])
        }
    }

    @Test
    fun matchesRefetchedChaptersByStableExtensionIdentity() {
        val first = object {
            @Suppress("unused")
            fun getUrl() = "/chapter/1"
            @Suppress("unused")
            fun getName() = "第一话"
            @Suppress("unused")
            fun getChapterNumber() = 1f
        }
        val second = object {
            @Suppress("unused")
            fun getUrl() = "/chapter/2"
            @Suppress("unused")
            fun getName() = "第二话"
            @Suppress("unused")
            fun getChapterNumber() = 2f
        }
        val encoded = mihonModelJson(second)

        assertFalse(mihonChapterMatches(first, encoded))
        assertTrue(mihonChapterMatches(second, encoded))
    }

    @Test
    fun preservesCurrentAbiMemoAcrossOpaqueChapterIdentity() {
        val encoded = mihonModelJson(
            object {
                @Suppress("unused")
                fun getMemo() = """{"size":42}"""
            },
        )

        assertNotNull(encoded.optJSONObject("memo"))
        assertEquals(42, encoded.getJSONObject("memo").getInt("size"))
    }
}
