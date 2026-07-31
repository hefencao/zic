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
    }

    @Test
    fun injectsApplicationBeforeNetworkHelperLikeMihonAppModule() {
        val application = Application()
        val network = Any()

        assertEquals(
            listOf(Application::class.java, String::class.java),
            mihonInjektSingletons(application, String::class.java, network).map { it.first },
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
    fun preservesEveryRealChapterAndSynthesizesOnlyForAnEmptyCatalog() {
        var syntheticCalls = 0
        val real = listOf("chapter-1", "chapter-2", "chapter-3")

        val selected = selectMihonChapters(real) {
            syntheticCalls++
            "synthetic"
        }

        assertEquals(real, selected.chapters)
        assertFalse(selected.synthetic)
        assertEquals(0, syntheticCalls)

        val empty = selectMihonChapters(emptyList<String>()) {
            syntheticCalls++
            "正文"
        }
        assertEquals(listOf("正文"), empty.chapters)
        assertTrue(empty.synthetic)
        assertEquals(1, syntheticCalls)
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
