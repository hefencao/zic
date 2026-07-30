package dev.zic.pluginhost

import android.content.Context
import android.os.Bundle
import io.flutter.plugin.common.StandardMessageCodec
import java.io.File
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
    const val MAX_REQUEST_BYTES = 512 * 1024
    const val INLINE_RESPONSE_BYTES = 128 * 1024
    const val MAX_RESPONSE_BYTES = 32 * 1024 * 1024
    const val REQUEST_TIMEOUT_MILLIS = 90_000L
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
        require(payloadLength in 0..RuntimeServiceIpc.MAX_RESPONSE_BYTES.toLong()) {
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

/// Pure file owner for large runtime responses.
///
/// This class is Android-free so service-death and packet-integrity behavior
/// can be tested without creating a FlutterEngine. The Android Bundle adapter
/// below only serializes this reference.
internal class RuntimeServicePacketFiles(private val root: File) {
    fun write(bytes: ByteArray): RuntimeServicePacketReference {
        require(bytes.size <= RuntimeServiceIpc.MAX_RESPONSE_BYTES) {
            "runtime response exceeds IPC limit"
        }
        val digest = sha256(bytes)
        if (bytes.size <= RuntimeServiceIpc.INLINE_RESPONSE_BYTES) {
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
                (file.name.endsWith(".packet") || file.name.endsWith(".part"))
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

    fun writeResponse(bytes: ByteArray): Bundle = files.write(bytes).toBundle()

    fun read(bundle: Bundle): ByteArray = files.read(bundle.toPacketReference())

    fun delete(bundle: Bundle) {
        runCatching { bundle.toPacketReference() }
            .onSuccess(files::delete)
    }

    fun clear() = files.clear()
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
