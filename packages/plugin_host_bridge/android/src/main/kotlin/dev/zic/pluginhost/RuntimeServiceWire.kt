package dev.zic.pluginhost

import android.content.Context
import android.os.Bundle
import io.flutter.plugin.common.StandardMessageCodec
import java.io.File
import java.io.InputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

internal object RuntimeServiceIpc {
    const val MESSAGE_REQUEST = 1
    const val MESSAGE_RESPONSE = 2
    const val KEY_REQUEST_ID = "requestId"
    const val KEY_INLINE_PAYLOAD = "inlinePayload"
    const val KEY_PAYLOAD_PATH = "payloadPath"
    const val KEY_PAYLOAD_LENGTH = "payloadLength"
    const val KEY_PAYLOAD_SHA256 = "payloadSha256"
    const val INLINE_REQUEST_BYTES = 512 * 1024
    const val MAX_PACKET_BYTES = 32 * 1024 * 1024
    const val MAX_REQUEST_BYTES = MAX_PACKET_BYTES
    const val INLINE_RESPONSE_BYTES = 128 * 1024
    const val MAX_RESPONSE_BYTES = MAX_PACKET_BYTES
    const val REQUEST_TIMEOUT_MILLIS = 65_000L
    const val CLAIM_BODY_METHOD = "claimExternalRuntimeResourceBody"
    const val RELEASE_BODY_METHOD = "releaseExternalRuntimeResourceBody"
    const val DISCARD_BODY_METHOD = "discardExternalRuntimeResourceBody"
}

internal object RuntimeServiceWireCodec {
    fun encode(value: Any?): ByteArray {
        val encoded = StandardMessageCodec.INSTANCE.encodeMessage(value)
            ?: return ByteArray(0)
        val readable = encoded.duplicate()
        if (readable.position() > 0) {
            readable.flip()
        }
        val bytes = ByteArray(readable.remaining())
        readable.get(bytes)
        return bytes
    }

    fun decode(bytes: ByteArray): Any? {
        if (bytes.isEmpty()) {
            return null
        }
        return StandardMessageCodec.INSTANCE.decodeMessage(ByteBuffer.wrap(bytes))
    }
}

internal data class RuntimeServicePacketReference(
    val inlinePayload: ByteArray?,
    val payloadPath: String?,
    val payloadLength: Long,
    val payloadSha256: String,
) {
    init {
        require((inlinePayload == null) != (payloadPath == null)) {
            "runtime IPC payload must have exactly one storage form"
        }
        require(payloadLength in 0..RuntimeServiceIpc.MAX_PACKET_BYTES.toLong()) {
            "runtime IPC payload length is invalid"
        }
        require(SHA256_PATTERN.matches(payloadSha256)) {
            "runtime IPC payload digest is invalid"
        }
        if (inlinePayload != null) {
            require(inlinePayload.size.toLong() == payloadLength) {
                "runtime IPC inline length mismatch"
            }
        }
    }

    companion object {
        private val SHA256_PATTERN = Regex("[0-9a-f]{64}")
    }
}

/// Raw encoded bytes, distinct from a StandardMessageCodec packet. No path is
/// accepted from the runtime: both names are derived by the private file owner.
internal data class RuntimeServiceBodyReference(
    val ownerId: String,
    val bodyId: String,
    val requestId: String,
    val externalSourceId: String,
    val runtimeId: String,
    val authorityRevision: String,
    val resourceUri: String,
    val byteLength: Long,
    val sha256: String,
    val fnv64: String,
    val metadataPrefix: ByteArray,
) {
    init {
        require(ownerId.startsWith("native-") && UUID_PATTERN.matches(ownerId.drop(7)))
        require(UUID_PATTERN.matches(bodyId))
        require(listOf(requestId, externalSourceId, runtimeId, authorityRevision, resourceUri)
            .all { it.isNotBlank() })
        require(byteLength in 0..RuntimeServiceIpc.MAX_RESPONSE_BYTES.toLong())
        require(Regex("[0-9a-f]{64}").matches(sha256))
        require(Regex("[0-9a-f-]{16,17}").matches(fnv64))
        require(metadataPrefix.size.toLong() == minOf(byteLength, 64L))
    }

    fun toMessage(): Map<String, Any?> = mapOf(
        "bodyDelivery" to DELIVERY,
        "ownerId" to ownerId,
        "bodyId" to bodyId,
        "requestId" to requestId,
        "externalSourceId" to externalSourceId,
        "runtimeId" to runtimeId,
        "authorityRevision" to authorityRevision,
        "resourceUri" to resourceUri,
        "byteLength" to byteLength,
        "sha256" to sha256,
        "fnv64" to fnv64,
        "metadataPrefix" to metadataPrefix,
    )

    companion object {
        const val DELIVERY = "sealed-file-v1"
        private val UUID_PATTERN = Regex(
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        )

        fun fromMessage(value: Any?): RuntimeServiceBodyReference {
            val map = value as? Map<*, *> ?: error("runtime body must be an object")
            require(map["bodyDelivery"] == DELIVERY)
            fun text(key: String) = map[key] as? String ?: error("$key is missing")
            val length = when (val raw = map["byteLength"]) {
                is Long -> raw
                is Int -> raw.toLong()
                else -> error("runtime body length is missing")
            }
            return RuntimeServiceBodyReference(
                text("ownerId"), text("bodyId"), text("requestId"),
                text("externalSourceId"), text("runtimeId"), text("authorityRevision"),
                text("resourceUri"), length, text("sha256"), text("fnv64"),
                map["metadataPrefix"] as? ByteArray ?: error("runtime body prefix is missing"),
            )
        }
    }
}

/// Pure file owner for large runtime request/response packets.
///
/// This class is Android-free so service-death and packet-integrity behavior
/// can be tested without creating a FlutterEngine. The Android Bundle adapter
/// below only serializes this reference.
internal class RuntimeServicePacketFiles(private val root: File) {
    fun writeBody(
        input: InputStream,
        ownerId: String,
        requestId: String,
        externalSourceId: String,
        runtimeId: String,
        authorityRevision: String,
        resourceUri: String,
        maxBytes: Int = RuntimeServiceIpc.MAX_RESPONSE_BYTES,
        checkCancelled: () -> Unit = {},
    ): RuntimeServiceBodyReference = writeBody(
        ownerId, requestId, externalSourceId, runtimeId, authorityRevision,
        resourceUri, maxBytes, checkCancelled,
    ) { output ->
        val chunk = ByteArray(64 * 1024)
        while (true) {
            checkCancelled()
            val count = input.read(chunk)
            checkCancelled()
            if (count < 0) break
            if (count == 0) continue
            output.write(chunk, 0, count)
        }
    }

    // The callback borrows one bounded stream; the file owner closes it before
    // sealing. This supports native encoders without an intermediate body array.
    fun writeBody(
        ownerId: String,
        requestId: String,
        externalSourceId: String,
        runtimeId: String,
        authorityRevision: String,
        resourceUri: String,
        maxBytes: Int = RuntimeServiceIpc.MAX_RESPONSE_BYTES,
        checkCancelled: () -> Unit = {},
        produce: (OutputStream) -> Unit,
    ): RuntimeServiceBodyReference {
        require(maxBytes in 0..RuntimeServiceIpc.MAX_RESPONSE_BYTES)
        require(ownerId.matches(Regex("native-[0-9a-f-]{36}")))
        check(root.mkdirs() || root.isDirectory)
        val bodyId = UUID.randomUUID().toString()
        val partial = File(root, "$ownerId-$bodyId.body.part")
        val sealed = File(root, "$ownerId-$bodyId.body")
        var published = false
        try {
            val output = BodyOutputStream(partial.outputStream().buffered(), maxBytes, checkCancelled)
            output.use {
                checkCancelled()
                produce(it)
                it.throwIfFailed()
                checkCancelled()
            }
            output.throwIfFailed()
            checkCancelled()
            check(partial.renameTo(sealed)) { "could not seal runtime body" }
            check(sealed.setReadOnly()) { "could not protect sealed runtime body" }
            val reference = RuntimeServiceBodyReference(
                ownerId, bodyId, requestId, externalSourceId, runtimeId,
                authorityRevision, resourceUri, output.length, hex(output.digest.digest()),
                output.fnv.toString(16).padStart(16, '0'),
                output.prefix.copyOf(minOf(output.length, 64L).toInt()),
            )
            checkCancelled()
            published = true
            return reference
        } finally {
            partial.delete()
            if (!published) sealed.delete()
        }
    }

    private class BodyOutputStream(
        private val output: OutputStream,
        private val maxBytes: Int,
        private val checkCancelled: () -> Unit,
    ) : OutputStream() {
        val digest = MessageDigest.getInstance("SHA-256")
        val prefix = ByteArray(64)
        var length = 0L
            private set
        var fnv = -3750763034362895579L
            private set
        private val singleByte = ByteArray(1)
        private var closed = false
        private var failure: Throwable? = null

        @Synchronized
        override fun write(value: Int) {
            singleByte[0] = value.toByte()
            write(singleByte, 0, 1)
        }

        @Synchronized
        override fun write(bytes: ByteArray, offset: Int, count: Int) {
            try {
                if (closed) throw IOException("runtime body writer is closed")
                throwIfFailed()
                require(offset >= 0 && count >= 0 && offset <= bytes.size - count)
                checkCancelled()
                require(length + count <= maxBytes) { "runtime body exceeds limit" }
                output.write(bytes, offset, count)
                if (length < 64) {
                    bytes.copyInto(
                        prefix, length.toInt(), offset,
                        offset + minOf(count, 64 - length.toInt()),
                    )
                }
                digest.update(bytes, offset, count)
                for (index in offset until offset + count) {
                    fnv = (fnv xor (bytes[index].toLong() and 0xffL)) * 0x100000001b3L
                }
                length += count
                checkCancelled()
            } catch (error: Throwable) {
                if (failure == null) failure = error
                throw error
            }
        }

        @Synchronized
        override fun flush() {
            try {
                if (closed) throw IOException("runtime body writer is closed")
                throwIfFailed()
                checkCancelled()
                output.flush()
                checkCancelled()
            } catch (error: Throwable) {
                if (failure == null) failure = error
                throw error
            }
        }

        @Synchronized
        override fun close() {
            if (closed) return
            closed = true
            try {
                output.close()
            } catch (error: Throwable) {
                if (failure == null) failure = error
                throw error
            }
        }

        @Synchronized
        fun throwIfFailed() {
            failure?.let { throw it }
        }
    }

    fun claimBody(
        reference: RuntimeServiceBodyReference,
        consumerId: String,
        checkCancelled: () -> Unit = {},
        openInput: (File) -> InputStream = { it.inputStream() },
    ): File {
        val body = bodyFile(reference, ".body")
        val claimed = claimedBodyFile(reference, consumerId)
        var admitted = false
        try {
            checkCancelled()
            require(body.isFile && body.length() == reference.byteLength) {
                "runtime body length mismatch"
            }
            check(!claimed.exists() && body.renameTo(claimed)) { "runtime body already claimed" }
            admitted = true
            val digest = MessageDigest.getInstance("SHA-256")
            val prefix = ByteArray(64)
            var length = 0L
            var fnv = -3750763034362895579L
            openInput(claimed).buffered().use { input ->
                val chunk = ByteArray(64 * 1024)
                while (true) {
                    checkCancelled()
                    val count = input.read(chunk)
                    checkCancelled()
                    if (count < 0) break
                    if (count == 0) continue
                    require(length + count <= reference.byteLength) {
                        "runtime body exceeds declared length"
                    }
                    if (length < 64) {
                        chunk.copyInto(prefix, length.toInt(), 0, minOf(count, 64 - length.toInt()))
                    }
                    digest.update(chunk, 0, count)
                    for (index in 0 until count) {
                        fnv = (fnv xor (chunk[index].toLong() and 0xffL)) * 0x100000001b3L
                    }
                    length += count
                }
            }
            require(length == reference.byteLength && hex(digest.digest()) == reference.sha256 &&
                fnv.toString(16).padStart(16, '0') == reference.fnv64 &&
                prefix.copyOf(minOf(length, 64L).toInt()).contentEquals(reference.metadataPrefix)) {
                "runtime body integrity mismatch"
            }
            checkCancelled()
            return claimed
        } catch (error: Throwable) {
            body.delete()
            if (admitted) claimed.delete()
            throw error
        }
    }

    fun deleteBody(reference: RuntimeServiceBodyReference) {
        bodyFile(reference, ".body").delete()
    }

    fun releaseBody(reference: RuntimeServiceBodyReference, consumerId: String) {
        claimedBodyFile(reference, consumerId).delete()
    }

    fun deleteBodyOwner(ownerId: String) {
        root.listFiles()?.forEach { file ->
            if (file.isFile && file.name.startsWith("$ownerId-") &&
                (file.name.endsWith(".body") || file.name.endsWith(".body.part"))) {
                file.delete()
            }
        }
    }

    fun clearStaleBodyLeases(consumerId: String) {
        require(consumerId.matches(Regex("[0-9a-f-]{36}")))
        root.listFiles()?.forEach { file ->
            if (file.isFile && file.name.endsWith(".lease") &&
                !file.name.startsWith("$consumerId-")) {
                file.delete()
            }
        }
    }

    private fun bodyFile(reference: RuntimeServiceBodyReference, suffix: String): File =
        confinedFile("${reference.ownerId}-${reference.bodyId}$suffix")

    private fun claimedBodyFile(reference: RuntimeServiceBodyReference, consumerId: String): File {
        require(consumerId.matches(Regex("[0-9a-f-]{36}")))
        return confinedFile("$consumerId-${reference.ownerId}-${reference.bodyId}.lease")
    }

    private fun confinedFile(name: String): File {
        val file = File(root, name).canonicalFile
        require(file.parentFile == root.canonicalFile) {
            "runtime body escaped app-private storage"
        }
        return file
    }

    fun write(
        bytes: ByteArray,
        inlineLimit: Int = RuntimeServiceIpc.INLINE_RESPONSE_BYTES,
    ): RuntimeServicePacketReference {
        require(bytes.size <= RuntimeServiceIpc.MAX_PACKET_BYTES) {
            "runtime IPC payload exceeds limit"
        }
        require(inlineLimit in 0..RuntimeServiceIpc.MAX_PACKET_BYTES) {
            "runtime IPC inline limit is invalid"
        }
        val digest = sha256(bytes)
        if (bytes.size <= inlineLimit) {
            return RuntimeServicePacketReference(
                inlinePayload = bytes,
                payloadPath = null,
                payloadLength = bytes.size.toLong(),
                payloadSha256 = digest,
            )
        }

        check(root.mkdirs() || root.isDirectory) {
            "could not create runtime IPC packet directory"
        }
        val token = UUID.randomUUID().toString()
        val partial = File(root, "$token.part")
        val promoted = File(root, "$token.packet")
        try {
            partial.outputStream().buffered().use { output ->
                output.write(bytes)
                output.flush()
            }
            check(partial.renameTo(promoted)) {
                "could not atomically promote runtime IPC response"
            }
            return RuntimeServicePacketReference(
                inlinePayload = null,
                payloadPath = promoted.path,
                payloadLength = bytes.size.toLong(),
                payloadSha256 = digest,
            )
        } finally {
            partial.delete()
        }
    }

    fun read(reference: RuntimeServicePacketReference): ByteArray {
        val inline = reference.inlinePayload
        if (inline != null) {
            require(sha256(inline) == reference.payloadSha256) {
                "runtime IPC inline digest mismatch"
            }
            return inline
        }

        val canonicalRoot = root.canonicalFile
        val file = File(requireNotNull(reference.payloadPath)).canonicalFile
        require(
            file.path.startsWith(canonicalRoot.path + File.separator) &&
                file.name.endsWith(".packet")
        ) {
            "runtime IPC payload escaped app-private storage"
        }
        return try {
            require(file.isFile && file.length() == reference.payloadLength) {
                "runtime IPC payload file is invalid"
            }
            require(reference.payloadLength <= Int.MAX_VALUE) {
                "runtime IPC payload is too large for the platform codec"
            }
            val result = ByteArray(reference.payloadLength.toInt())
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use { input ->
                var offset = 0
                while (offset < result.size) {
                    val count = input.read(result, offset, result.size - offset)
                    require(count > 0) {
                        "runtime IPC payload ended before its declared length"
                    }
                    digest.update(result, offset, count)
                    offset += count
                }
                require(input.read() == -1) {
                    "runtime IPC payload exceeded its declared length"
                }
            }
            require(hex(digest.digest()) == reference.payloadSha256) {
                "runtime IPC payload digest mismatch"
            }
            result
        } finally {
            file.delete()
        }
    }

    fun delete(reference: RuntimeServicePacketReference) {
        val path = reference.payloadPath ?: return
        val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return
        val file = runCatching { File(path).canonicalFile }.getOrNull() ?: return
        if (file.path.startsWith(canonicalRoot.path + File.separator) &&
            file.name.endsWith(".packet")
        ) {
            file.delete()
        }
    }

    fun clear() {
        root.listFiles()?.forEach { file ->
            if (file.isFile &&
                (file.name.endsWith(".packet") || file.name.endsWith(".part") ||
                    file.name.endsWith(".body"))
            ) {
                file.delete()
            }
        }
    }

    private fun sha256(bytes: ByteArray): String =
        hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString(separator = "") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
}

/// App-private spill files keep large binary comic resources out of Binder's
/// transaction-size limit. Both processes run under the same app UID.
internal class RuntimeServicePacketStore(context: Context) {
    private val files = RuntimeServicePacketFiles(
        File(context.cacheDir, "zic-plugin-runtime-ipc"),
    )

    fun writeRequest(bytes: ByteArray): Bundle =
        files.write(bytes, RuntimeServiceIpc.INLINE_REQUEST_BYTES).toBundle()

    fun writeResponse(bytes: ByteArray): Bundle =
        files.write(bytes, RuntimeServiceIpc.INLINE_RESPONSE_BYTES).toBundle()

    fun read(bundle: Bundle): ByteArray = files.read(bundle.toPacketReference())

    fun delete(bundle: Bundle) {
        runCatching { bundle.toPacketReference() }
            .onSuccess(files::delete)
    }

    fun clear() = files.clear()

    fun claimBody(value: Any?, checkCancelled: () -> Unit = {}): String =
        files.claimBody(
            RuntimeServiceBodyReference.fromMessage(value), BODY_CONSUMER_ID, checkCancelled,
        ).path

    fun releaseBody(value: Any?) =
        files.releaseBody(RuntimeServiceBodyReference.fromMessage(value), BODY_CONSUMER_ID)

    fun discardBody(value: Any?) = files.deleteBody(RuntimeServiceBodyReference.fromMessage(value))

    fun deleteEnvelopeBody(value: Any?) {
        bodyFromEnvelope(value)?.let { runCatching { files.deleteBody(it) } }
    }

    fun bodyFromEnvelope(value: Any?): RuntimeServiceBodyReference? {
        val envelope = value as? Map<*, *> ?: return null
        val response = envelope["result"] as? Map<*, *> ?: return null
        val payload = response["payload"] as? Map<*, *> ?: return null
        if (payload["bodyDelivery"] != RuntimeServiceBodyReference.DELIVERY) return null
        return runCatching { RuntimeServiceBodyReference.fromMessage(payload) }.getOrNull()
    }

    fun clearStaleBodyLeases() = files.clearStaleBodyLeases(BODY_CONSUMER_ID)

    companion object {
        // Shared by all clients in this process. A second engine must not
        // reclaim the first engine's admitted physical reads.
        private val BODY_CONSUMER_ID = UUID.randomUUID().toString()
    }
}

private fun RuntimeServicePacketReference.toBundle(): Bundle = Bundle().apply {
    inlinePayload?.let { putByteArray(RuntimeServiceIpc.KEY_INLINE_PAYLOAD, it) }
    payloadPath?.let { putString(RuntimeServiceIpc.KEY_PAYLOAD_PATH, it) }
    putLong(RuntimeServiceIpc.KEY_PAYLOAD_LENGTH, payloadLength)
    putString(RuntimeServiceIpc.KEY_PAYLOAD_SHA256, payloadSha256)
}

private fun Bundle.toPacketReference(): RuntimeServicePacketReference =
    RuntimeServicePacketReference(
        inlinePayload = getByteArray(RuntimeServiceIpc.KEY_INLINE_PAYLOAD),
        payloadPath = getString(RuntimeServiceIpc.KEY_PAYLOAD_PATH),
        payloadLength = getLong(RuntimeServiceIpc.KEY_PAYLOAD_LENGTH, -1L),
        payloadSha256 = getString(RuntimeServiceIpc.KEY_PAYLOAD_SHA256)
            ?: error("runtime IPC payload digest is missing"),
    )
