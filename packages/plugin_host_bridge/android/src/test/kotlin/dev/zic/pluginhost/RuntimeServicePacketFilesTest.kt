package dev.zic.pluginhost

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RuntimeServicePacketFilesTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun largeResponseUsesPacketAndDeletesAfterConsumption() {
        val root = temporary.newFolder("packets")
        val store = RuntimeServicePacketFiles(root)
        val bytes = ByteArray(RuntimeServiceIpc.INLINE_RESPONSE_BYTES + 4096) {
            (it % 251).toByte()
        }

        val reference = store.write(bytes)
        val packet = File(requireNotNull(reference.payloadPath))
        assertNotNull(reference.payloadPath)
        assertNull(reference.inlinePayload)
        assertArrayEquals(bytes, store.read(reference))
        assertFalse(packet.exists())
        assertFalse(root.listFiles().orEmpty().any { it.name.endsWith(".part") })
    }

    @Test
    fun tamperedPacketIsRejectedAndDeleted() {
        val root = temporary.newFolder("tampered")
        val store = RuntimeServicePacketFiles(root)
        val bytes = ByteArray(RuntimeServiceIpc.INLINE_RESPONSE_BYTES + 1) { 7 }
        val reference = store.write(bytes)
        val packet = File(requireNotNull(reference.payloadPath))
        packet.outputStream().use { output ->
            output.write(ByteArray(bytes.size) { 8 })
        }

        assertThrows(IllegalArgumentException::class.java) {
            store.read(reference)
        }
        assertFalse(packet.exists())
    }

    @Test
    fun packetPathCannotEscapeDedicatedRoot() {
        val root = temporary.newFolder("root")
        val outside = temporary.newFile("outside.packet")
        outside.writeBytes(byteArrayOf(1, 2, 3))
        val reference = RuntimeServicePacketReference(
            inlinePayload = null,
            payloadPath = outside.path,
            payloadLength = 3,
            payloadSha256 = "0".repeat(64),
        )

        val store = RuntimeServicePacketFiles(root)
        assertThrows(IllegalArgumentException::class.java) {
            store.read(reference)
        }
        assertTrue(outside.exists())
    }
}
