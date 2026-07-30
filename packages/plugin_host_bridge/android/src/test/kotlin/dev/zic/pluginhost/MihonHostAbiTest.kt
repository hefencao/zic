package dev.zic.pluginhost

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MihonHostAbiTest {
    @Test
    fun reportsMissingClassesForTheSelectedLoaderOnly() {
        val missing = setOf("androidx.preference.Preference", "uy.kohesive.injekt.InjektKt")
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
            listOf("androidx.preference.Preference", "uy.kohesive.injekt.InjektKt"),
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
    fun extensionAndSourceApiPackagesAreChildFirstButCommonLibrariesAreNot() {
        assertTrue(isMihonChildFirstClass("eu.kanade.tachiyomi.extension.all.ehentai.EHFactory"))
        assertTrue(isMihonChildFirstClass("eu.kanade.tachiyomi.source.online.HttpSource"))
        assertFalse(isMihonChildFirstClass("androidx.preference.Preference"))
        assertFalse(isMihonChildFirstClass("okhttp3.OkHttpClient"))
        assertFalse(isMihonChildFirstClass("uy.kohesive.injekt.InjektKt"))
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
}
