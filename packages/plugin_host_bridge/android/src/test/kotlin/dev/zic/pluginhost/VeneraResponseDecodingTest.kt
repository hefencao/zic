package dev.zic.pluginhost

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.DeflaterOutputStream
import java.util.zip.GZIPOutputStream

class VeneraResponseDecodingTest {
    @Test
    fun decodesGzipAndDeflateBeforeApplyingTheResponseLimit() {
        val payload = """{"items":[1,2,3]}""".toByteArray()

        assertArrayEquals(
            payload,
            readDecodedResponseBytes(
                ByteArrayInputStream(gzip(payload)),
                "gzip",
                payload.size,
            ),
        )
        assertArrayEquals(
            payload,
            readDecodedResponseBytes(
                ByteArrayInputStream(deflate(payload)),
                "deflate",
                payload.size,
            ),
        )
        assertThrows(IllegalArgumentException::class.java) {
            readDecodedResponseBytes(
                ByteArrayInputStream(gzip(payload)),
                "gzip",
                payload.size - 1,
            )
        }
    }

    private fun gzip(value: ByteArray): ByteArray =
        ByteArrayOutputStream().use { output ->
            GZIPOutputStream(output).use { it.write(value) }
            output.toByteArray()
        }

    private fun deflate(value: ByteArray): ByteArray =
        ByteArrayOutputStream().use { output ->
            DeflaterOutputStream(output).use { it.write(value) }
            output.toByteArray()
        }
}
