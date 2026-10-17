package dev.zic.comic_translation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class HyMtRuntimeLoaderTest {
    private val features = listOf(0, 1, 7, 8, 12, 20)
    private val supported = features.fold(0L) { mask, bit -> mask or (1L shl bit) }

    @Test fun unsupportedCpusNeverLoadOptimizedCode() {
        for (mask in listOf(0L, 3L) + features.map { supported and (1L shl it).inv() }) {
            val loaded = mutableListOf<String>()
            assertNotNull(HyMtRuntimeLoader.load({ loaded.add(it) }, { mask }))
            assertEquals(listOf("zic_translation_cpu"), loaded)
        }
    }

    @Test fun supportedCpusAreProbedBeforeLoadingTheRuntime() {
        val events = mutableListOf<String>()
        assertNull(HyMtRuntimeLoader.load({ events.add(it) }, {
            events.add("probe")
            supported or (1L shl 22)
        }))
        assertEquals(listOf("zic_translation_cpu", "probe", "zic_hymt"), events)
    }

    @Test fun missingProbeDoesNotCallNativeOrLoadTheRuntime() {
        val failure = UnsatisfiedLinkError("missing probe")
        assertSame(failure, HyMtRuntimeLoader.load({ throw failure }, {
            throw AssertionError("probe library was not loaded")
        }))
    }

    @Test fun missingRuntimeRemainsAnAvailabilityFailure() {
        val failure = UnsatisfiedLinkError("missing runtime")
        assertSame(failure, HyMtRuntimeLoader.load({
            if (it == "zic_hymt") throw failure
        }, { supported }))
    }
}
