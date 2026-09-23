package dev.zic.pluginhost

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VeneraAdaptiveReaderTypeTest {
    @Test
    fun normalizesSupportedAdaptiveReaderHints() {
        assertEquals("paged", normalizeVeneraAdaptiveReaderType("paged"))
        assertEquals("paged", normalizeVeneraAdaptiveReaderType("manga"))
        assertEquals("vertical", normalizeVeneraAdaptiveReaderType("webtoon"))
        assertEquals("vertical", normalizeVeneraAdaptiveReaderType("manhwa"))
        assertEquals("animated", normalizeVeneraAdaptiveReaderType("animated"))
        assertNull(normalizeVeneraAdaptiveReaderType(""))
        assertNull(normalizeVeneraAdaptiveReaderType("unknown"))
    }
}
