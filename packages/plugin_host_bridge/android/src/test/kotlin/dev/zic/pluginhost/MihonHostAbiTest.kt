package dev.zic.pluginhost

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
