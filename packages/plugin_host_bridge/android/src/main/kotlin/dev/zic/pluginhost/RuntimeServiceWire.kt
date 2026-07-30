package dev.zic.pluginhost

import android.content.Context
import android.os.Bundle
import io.flutter.plugin.common.StandardMessageCodec
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID

internal object RuntimeServiceIpc {
    const val MESSAGE_REQUEST = 1
    const val MESSAGE_RESPONSE = 2
    const val KEY_REQUEST_ID = "requestId"
    const val KEY_INLINE_PAYLOAD = "inlinePayload"
    const val KEY_PAYLOAD_PATH = "payloadPath"
    const val KEY_PAYLOAD_LENGTH = "payloadLength"
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

/// App-private spill files keep large binary comic resources out of Binder's
/// transaction-size limit. Both processes run under the same app UID.
internal class RuntimeServicePacketStore(context: Context) {
    private val root = File(context.cacheDir, "zic-plugin-runtime-ipc")

    fun writeResponse(bytes: ByteArray): Bundle {
        require(bytes.size <= RuntimeServiceIpc.MAX_RESPONSE_BYTES) {
            "runtime response exceeds IPC limit"
        }
        return if (bytes.size <= RuntimeServiceIpc.INLINE_RESPONSE_BYTES) {
            Bundle().apply {
                putByteArray(RuntimeServiceIpc.KEY_INLINE_PAYLOAD, bytes)
                putLong(RuntimeServiceIpc.KEY_PAYLOAD_LENGTH, bytes.size.toLong())
            }
        } else {
            root.mkdirs()
            val token = UUID.randomUUID().toString()
            val partial = File(root, "$token.part")
            val promoted = File(root, "$token.packet")
            partial.outputStream().buffered().use { output ->
                output.write(bytes)
                output.flush()
            }
            check(partial.renameTo(promoted)) {
                "could not atomically promote runtime IPC response"
            }
            Bundle().apply {
                putString(RuntimeServiceIpc.KEY_PAYLOAD_PATH, promoted.path)
                putLong(RuntimeServiceIpc.KEY_PAYLOAD_LENGTH, bytes.size.toLong())
            }
        }
    }

    fun read(bundle: Bundle): ByteArray {
        val inline = bundle.getByteArray(RuntimeServiceIpc.KEY_INLINE_PAYLOAD)
        val declaredLength = bundle.getLong(RuntimeServiceIpc.KEY_PAYLOAD_LENGTH, -1L)
        if (inline != null) {
            require(declaredLength == inline.size.toLong()) {
                "runtime IPC inline length mismatch"
            }
            return inline
        }
        val path = bundle.getString(RuntimeServiceIpc.KEY_PAYLOAD_PATH)
            ?: error("runtime IPC payload is missing")
        require(declaredLength in 0..RuntimeServiceIpc.MAX_RESPONSE_BYTES.toLong()) {
            "runtime IPC payload length is invalid"
        }
        val canonicalRoot = root.canonicalFile
        val file = File(path).canonicalFile
        require(
            file.path.startsWith(canonicalRoot.path + File.separator) &&
                file.name.endsWith(".packet")
        ) {
            "runtime IPC payload escaped app-private storage"
        }
        return try {
            require(file.isFile && file.length() == declaredLength) {
                "runtime IPC payload file is invalid"
            }
            file.readBytes()
        } finally {
            file.delete()
        }
    }

    fun delete(bundle: Bundle) {
        val path = bundle.getString(RuntimeServiceIpc.KEY_PAYLOAD_PATH) ?: return
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
}
