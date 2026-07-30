package dev.zic.pluginhost

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MihonHostAbiTest {
    @Test
    fun reportsEveryMissingHostAbiClassWithoutLoadingPluginCode() {
        val missing = setOf(
            "androidx.preference.Preference",
            "uy.kohesive.injekt.InjektKt",
        )
        val loader = object : ClassLoader(null) {
            override fun loadClass(name: String): Class<*> {
                if (name in missing) throw ClassNotFoundException(name)
                return String::class.java
            }
        }

        assertEquals(missing.toList(), missingMihonHostAbiClasses(loader))
        assertTrue(requiredMihonHostAbiClasses.contains("eu.kanade.tachiyomi.source.Source"))
        assertTrue(requiredMihonHostAbiClasses.contains("androidx.preference.Preference"))
        assertTrue(requiredMihonHostAbiClasses.contains("uy.kohesive.injekt.InjektKt"))
    }

    @Test
    fun derivesCurrentExtensionAbiFromVersionNameWhenMetadataIsAbsent() {
        assertEquals("1.6", normalizeMihonExtensionLib(null, "1.6.4"))
        assertEquals("1.6", normalizeMihonExtensionLib("", "1.6.4"))
        assertEquals("1.6", normalizeMihonExtensionLib("1.6", "9.9.9"))
        assertEquals("16", normalizeMihonExtensionLib(16, "9.9.9"))
        assertEquals(null, normalizeMihonExtensionLib(null, "invalid"))
    }
}
