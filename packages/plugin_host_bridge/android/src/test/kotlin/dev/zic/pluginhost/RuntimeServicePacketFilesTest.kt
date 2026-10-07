package dev.zic.pluginhost

import java.io.File
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.OutputStream
import java.lang.reflect.InvocationTargetException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
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
    fun requestAboveBinderInlineLimitUsesSameVerifiedPacketLifecycle() {
        val root = temporary.newFolder("request-packets")
        val store = RuntimeServicePacketFiles(root)
        val bytes = ByteArray(RuntimeServiceIpc.INLINE_REQUEST_BYTES + 4096) {
            (it % 239).toByte()
        }

        val reference = store.write(bytes, RuntimeServiceIpc.INLINE_REQUEST_BYTES)
        val packet = File(requireNotNull(reference.payloadPath))
        assertNull(reference.inlinePayload)
        assertArrayEquals(bytes, store.read(reference))
        assertFalse(packet.exists())
        assertFalse(root.listFiles().orEmpty().any { it.name.endsWith(".part") })
    }

    @Test
    fun requestAtBinderInlineLimitStaysInline() {
        val root = temporary.newFolder("inline-request")
        val store = RuntimeServicePacketFiles(root)
        val bytes = ByteArray(RuntimeServiceIpc.INLINE_REQUEST_BYTES) { 11 }

        val reference = store.write(bytes, RuntimeServiceIpc.INLINE_REQUEST_BYTES)

        assertArrayEquals(bytes, reference.inlinePayload)
        assertNull(reference.payloadPath)
        assertArrayEquals(bytes, store.read(reference))
        assertTrue(root.listFiles().orEmpty().isEmpty())
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

    @Test
    fun sealedBodyIsRawBinaryAndPreservesLegacyDartValidator() {
        val root = temporary.newFolder("bodies")
        val store = RuntimeServicePacketFiles(root)
        val bytes = ByteArray(131081) { (it % 251).toByte() }
        val reference = writeBody(store, bytes)
        assertTrue(reference.fnv64 == "-148785d5f683dbd2")
        assertTrue(reference.byteLength == bytes.size.toLong())
        assertArrayEquals(bytes.copyOf(64), reference.metadataPrefix)
        assertTrue(RuntimeServiceWireCodec.encode(reference.toMessage()).size < 2048)
        val claimed = store.claimBody(reference, CONSUMER)
        assertArrayEquals(bytes, claimed.readBytes())
        store.releaseBody(reference, CONSUMER)
        store.releaseBody(reference, CONSUMER)
        assertFalse(claimed.exists())
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun directProducerSealsExactlyTheSameBodyProofAsStreamInput() {
        val root = temporary.newFolder("body-direct-producer")
        val store = RuntimeServicePacketFiles(root)
        val bytes = ByteArray(131081) { (it % 251).toByte() }
        val streamReference = writeBody(store, bytes)
        val produced = writeProducedBody(store) { output ->
            output.write(bytes[0].toInt())
            output.write(bytes, 1, 63)
            output.flush()
            output.write(bytes, 64, 0)
            output.write(bytes, 64, bytes.size - 64)
        }
        assertTrue(produced.byteLength == streamReference.byteLength)
        assertTrue(produced.sha256 == streamReference.sha256)
        assertTrue(produced.fnv64 == streamReference.fnv64)
        assertTrue(produced.fnv64 == "-148785d5f683dbd2")
        assertArrayEquals(streamReference.metadataPrefix, produced.metadataPrefix)
        val claimed = store.claimBody(produced, CONSUMER)
        assertArrayEquals(bytes, claimed.readBytes())
        store.releaseBody(produced, CONSUMER)
        store.deleteBody(streamReference)
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun producerFailureCannotPublishItsWrittenPrefix() {
        val root = temporary.newFolder("body-producer-failure")
        val store = RuntimeServicePacketFiles(root)
        assertThrows(java.io.IOException::class.java) {
            writeProducedBody(store) { output ->
                output.write(ByteArray(20) { 7 })
                throw java.io.IOException("encoding failed")
            }
        }
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun swallowedProducerLimitFailureStillPreventsPublication() {
        val root = temporary.newFolder("body-producer-limit")
        val store = RuntimeServicePacketFiles(root)
        assertThrows(IllegalArgumentException::class.java) {
            writeProducedBody(store, maxBytes = 8) { output ->
                output.write(ByteArray(8) { 9 })
                try {
                    output.write(9)
                } catch (_: IllegalArgumentException) {
                    // Some native encoders report failure instead of rethrowing.
                }
            }
        }
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun cancellationJoinsProducerReturnBeforeDeletingUnpublishedBody() {
        val root = temporary.newFolder("body-producer-cancel")
        val store = RuntimeServicePacketFiles(root)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val work = executor.submit {
                assertThrows(InterruptedException::class.java) {
                    writeProducedBody(store, checkCancelled = {
                        if (cancelled.get()) throw InterruptedException()
                    }) { output ->
                        output.write(ByteArray(20) { 7 })
                        entered.countDown()
                        check(release.await(5, TimeUnit.SECONDS))
                        // No next write: the owner must check cancellation on return.
                    }
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            cancelled.set(true)
            assertFalse(work.isDone)
            assertFalse(root.listFiles().orEmpty().any { it.name.endsWith(".body") })
            release.countDown()
            work.get(5, TimeUnit.SECONDS)
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun retainedProducerStreamCannotChangeASealedBody() {
        val root = temporary.newFolder("body-producer-retired")
        val store = RuntimeServicePacketFiles(root)
        var retained: OutputStream? = null
        val reference = writeProducedBody(store) { output ->
            retained = output
            output.write(byteArrayOf(7, 8, 9))
        }
        assertThrows(java.io.IOException::class.java) { retained!!.write(10) }
        val claimed = store.claimBody(reference, CONSUMER)
        assertArrayEquals(byteArrayOf(7, 8, 9), claimed.readBytes())
        store.releaseBody(reference, CONSUMER)
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun runtimeDeathAndDriverCloseLeaveClaimedBodyForPhysicalConsumer() {
        val root = temporary.newFolder("body-retirement")
        val store = RuntimeServicePacketFiles(root)
        val reference = writeBody(store, ByteArray(200) { 11 })
        val claimed = store.claimBody(reference, CONSUMER)
        val unclaimed = writeBody(store, ByteArray(200) { 12 })
        store.deleteBodyOwner(OWNER)
        store.clear()
        assertTrue(claimed.exists())
        assertFalse(root.listFiles().orEmpty().any { it.name.contains(unclaimed.bodyId) })
        store.clearStaleBodyLeases(CONSUMER)
        assertTrue(claimed.exists())
        store.releaseBody(reference, CONSUMER)
        assertFalse(claimed.exists())
    }

    @Test
    fun aNewHostProcessReclaimsOnlyPreviousProcessBodyLeases() {
        val root = temporary.newFolder("body-process-death")
        val store = RuntimeServicePacketFiles(root)
        val stale = store.claimBody(writeBody(store, ByteArray(200)), CONSUMER)
        val live = store.claimBody(writeBody(store, ByteArray(200)), NEXT_CONSUMER)
        store.clearStaleBodyLeases(NEXT_CONSUMER)
        assertFalse(stale.exists())
        assertTrue(live.exists())
    }

    @Test
    fun equalLengthTamperedBodyIsRejectedBeforePublicationAndRemoved() {
        val root = temporary.newFolder("body-tamper")
        val store = RuntimeServicePacketFiles(root)
        val reference = writeBody(store, ByteArray(200) { 7 })
        val body = root.listFiles().orEmpty().single()
        body.setWritable(true)
        body.writeBytes(ByteArray(200) { 8 })
        assertThrows(IllegalArgumentException::class.java) {
            store.claimBody(reference, CONSUMER)
        }
        assertFalse(body.exists())
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun metadataCannotOverrideVerifiedBodyContentOrEscapePrivateRoot() {
        val root = temporary.newFolder("body-reference")
        val store = RuntimeServicePacketFiles(root)
        val reference = writeBody(store, ByteArray(200) { 7 })
        assertThrows(IllegalArgumentException::class.java) {
            store.claimBody(reference.copy(metadataPrefix = ByteArray(64)), CONSUMER)
        }
        assertTrue(root.listFiles().orEmpty().isEmpty())
        val another = writeBody(store, ByteArray(200) { 9 })
        val body = root.listFiles().orEmpty().single()
        val outside = temporary.newFile("outside.body")
        outside.writeBytes(ByteArray(200) { 9 })
        body.delete()
        Files.createSymbolicLink(body.toPath(), outside.toPath())
        assertThrows(IllegalArgumentException::class.java) {
            store.claimBody(another, CONSUMER)
        }
        assertTrue(outside.exists())
        assertArrayEquals(ByteArray(200) { 9 }, outside.readBytes())
        assertThrows(IllegalArgumentException::class.java) {
            another.copy(bodyId = "../outside")
        }
    }

    @Test
    fun cancellationWaitsForBlockedProducerReadAndDeletesUnpublishedBody() {
        val root = temporary.newFolder("body-cancel")
        val store = RuntimeServicePacketFiles(root)
        val started = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val closed = AtomicBoolean(false)
        val input = object : InputStream() {
            override fun read(): Int = error("bounded read is required")
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                assertTrue(length <= 64 * 1024)
                started.countDown()
                check(finish.await(5, TimeUnit.SECONDS))
                bytes[offset] = 7
                return 1
            }
            override fun close() { closed.set(true) }
        }
        val executor = Executors.newSingleThreadExecutor()
        try {
            val work = executor.submit {
                input.use {
                    assertThrows(InterruptedException::class.java) {
                        store.writeBody(
                            input = it, ownerId = OWNER, requestId = "body-request",
                            externalSourceId = "fixture", runtimeId = "fixture-runtime",
                            authorityRevision = "payload-v3", resourceUri = "mihon:resource:unchanged",
                            checkCancelled = { if (cancelled.get()) throw InterruptedException() },
                        )
                    }
                }
            }
            assertTrue(started.await(5, TimeUnit.SECONDS))
            cancelled.set(true)
            assertFalse(work.isDone)
            assertFalse(closed.get())
            finish.countDown()
            work.get(5, TimeUnit.SECONDS)
            assertTrue(closed.get())
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally {
            finish.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun bodyLimitFailureLeavesNoPartialOrSealedFile() {
        val root = temporary.newFolder("body-limit")
        val store = RuntimeServicePacketFiles(root)
        assertThrows(IllegalArgumentException::class.java) {
            store.writeBody(
                input = ByteArrayInputStream(ByteArray(9)), ownerId = OWNER,
                requestId = "body-request", externalSourceId = "fixture",
                runtimeId = "fixture-runtime", authorityRevision = "payload-v3",
                resourceUri = "mihon:resource:unchanged", maxBytes = 8,
            )
        }
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun cancellationDuringIntegrityReadWaitsForPhysicalExitBeforeRemovingLease() {
        val root = temporary.newFolder("body-claim-cancel")
        val store = RuntimeServicePacketFiles(root)
        val reference = writeBody(store, ByteArray(200) { 7 })
        val started = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val closed = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val work = executor.submit {
                assertThrows(InterruptedException::class.java) {
                    store.claimBody(
                        reference, CONSUMER,
                        checkCancelled = { if (cancelled.get()) throw InterruptedException() },
                        openInput = { file ->
                            object : java.io.FilterInputStream(file.inputStream()) {
                                override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                                    started.countDown()
                                    check(finish.await(5, TimeUnit.SECONDS))
                                    return super.read(bytes, offset, length)
                                }
                                override fun close() {
                                    super.close()
                                    closed.set(true)
                                }
                            }
                        },
                    )
                }
            }
            assertTrue(started.await(5, TimeUnit.SECONDS))
            cancelled.set(true)
            assertFalse(work.isDone)
            assertFalse(closed.get())
            assertTrue(root.listFiles().orEmpty().single().name.endsWith(".lease"))
            finish.countDown()
            work.get(5, TimeUnit.SECONDS)
            assertTrue(closed.get())
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally {
            finish.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun sourceRetirementDuringIntegrityReadPreservesAdmittedLease() {
        val root = temporary.newFolder("body-claim-retirement")
        val store = RuntimeServicePacketFiles(root)
        val bytes = ByteArray(200) { 9 }
        val reference = writeBody(store, bytes)
        val claimed = store.claimBody(reference, CONSUMER, openInput = { file ->
            store.deleteBodyOwner(OWNER)
            store.clear()
            assertTrue(file.exists())
            file.inputStream()
        })
        assertArrayEquals(bytes, claimed.readBytes())
        store.releaseBody(reference, CONSUMER)
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    private fun writeBody(store: RuntimeServicePacketFiles, bytes: ByteArray) =
        store.writeBody(
            input = ByteArrayInputStream(bytes), ownerId = OWNER, requestId = "body-request",
            externalSourceId = "fixture", runtimeId = "fixture-runtime",
            authorityRevision = "payload-v3", resourceUri = "mihon:resource:unchanged",
        )

    // Reflection keeps the same behavior fixture executable against the old
    // owner, where the producer capability is absent, as well as the new owner.
    private fun writeProducedBody(
        store: RuntimeServicePacketFiles,
        maxBytes: Int = RuntimeServiceIpc.MAX_RESPONSE_BYTES,
        checkCancelled: () -> Unit = {},
        produce: (OutputStream) -> Unit,
    ): RuntimeServiceBodyReference {
        val method = RuntimeServicePacketFiles::class.java.declaredMethods.singleOrNull {
            it.name == "writeBody" && it.parameterTypes.lastOrNull() ==
                kotlin.jvm.functions.Function1::class.java
        }
        assertNotNull("body owner cannot accept a direct encoded-byte producer", method)
        return try {
            method!!.invoke(
                store, OWNER, "body-request", "fixture", "fixture-runtime",
                "payload-v3", "venera:resource:unchanged", maxBytes, checkCancelled, produce,
            ) as RuntimeServiceBodyReference
        } catch (error: InvocationTargetException) {
            throw requireNotNull(error.cause)
        }
    }

    companion object {
        private const val OWNER = "native-11111111-1111-1111-1111-111111111111"
        private const val CONSUMER = "22222222-2222-2222-2222-222222222222"
        private const val NEXT_CONSUMER = "33333333-3333-3333-3333-333333333333"
    }
}
