package dev.zic.localmedia

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalMediaFormatTest {
    @Test
    fun `header sniffing recognizes WebP independently of filename`() {
        val bytes = byteArrayOf(
            'R'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), 'F'.code.toByte(),
            0, 0, 0, 0,
            'W'.code.toByte(), 'E'.code.toByte(), 'B'.code.toByte(), 'P'.code.toByte(),
            'J'.code.toByte(), 'U'.code.toByte(), 'N'.code.toByte(), 'K'.code.toByte(),
        )

        assertEquals("webp", sniffImageFormat(bytes))
        assertEquals("header", resolveImageFormat(bytes, "application/octet-stream", "page.data")?.origin)
    }

    @Test
    fun `provider metadata is a fallback after header sniffing`() {
        assertEquals(
            ImageFormatResolution("webp", "mime"),
            resolveImageFormat(byteArrayOf(), "image/webp", "page.data"),
        )
        assertEquals(
            ImageFormatResolution("webp", "name"),
            resolveImageFormat(byteArrayOf(), "application/octet-stream", "page.WEBP"),
        )
        assertNull(resolveImageFormat("plain text".toByteArray(), "text/plain", "notes.txt"))
    }

    @Test
    fun `failed header probe retains image metadata as deferred candidate`() {
        assertEquals(
            ImageFormatResolution("webp", "mime-deferred"),
            resolveDirectoryCandidate(null, "image/webp", "page.data"),
        )
        assertEquals(
            ImageFormatResolution("webp", "name-deferred"),
            resolveDirectoryCandidate(null, "application/octet-stream", "page.WEBP"),
        )
        assertNull(resolveDirectoryCandidate(null, "text/plain", "notes.txt"))
    }

    @Test
    fun `natural ordering keeps numeric pages in reading order`() {
        val pages = mutableListOf("10.webp", "2.webp", "001.webp")
        pages.sortWith(Comparator(::naturalCompare))
        assertEquals(listOf("001.webp", "2.webp", "10.webp"), pages)
    }

    @Test
    fun `truncated WebP labels are rejected`() {
        val truncatedLabel = byteArrayOf(
            'R'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), 'F'.code.toByte(),
            0, 0, 0, 0,
            'W'.code.toByte(), 'E'.code.toByte(), 'B'.code.toByte(),
        )
        val missingChunkTag = byteArrayOf(
            'R'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), 'F'.code.toByte(),
            0, 0, 0, 0,
            'W'.code.toByte(), 'E'.code.toByte(), 'B'.code.toByte(), 'P'.code.toByte(),
        )

        assertNull(sniffImageFormat(truncatedLabel))
        assertNull(sniffImageFormat(missingChunkTag))
    }
}
