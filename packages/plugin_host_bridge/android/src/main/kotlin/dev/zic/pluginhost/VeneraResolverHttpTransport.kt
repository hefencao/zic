package dev.zic.pluginhost

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.net.URL
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private const val VENERA_RESOLVER_LOG_TAG = "ZicPluginRuntime"

internal data class VeneraResolverHttpResult(
    val status: Int,
    val headers: Map<String, List<String>>,
    val body: ByteArray,
)

internal interface VeneraResolverHttpTransport : Closeable {
    fun execute(
        target: URL,
        method: String,
        headers: Map<String, String>,
        bodyBytes: ByteArray,
        requestId: String?,
        maxResponseBytes: Int,
    ): VeneraResolverHttpResult

    fun cancel(requestId: String)
}

/// Synchronous facade required by Venera's JavascriptInterface bridge.
///
/// The actual HTTP client lives in the isolated plugin Dart process and uses
/// rhttp/reqwest. Kotlin only marshals one normalized request and waits for the
/// Dart-owned result; it does not own a second connection pool.
internal class DartRhttpVeneraResolverTransport(
    private val channel: MethodChannel,
) : VeneraResolverHttpTransport {
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var closed = false

    override fun execute(
        target: URL,
        method: String,
        headers: Map<String, String>,
        bodyBytes: ByteArray,
        requestId: String?,
        maxResponseBytes: Int,
    ): VeneraResolverHttpResult {
        check(!closed) { "Venera resolver HTTP transport is closed" }
        check(Looper.myLooper() != Looper.getMainLooper()) {
            "Venera resolver HTTP must not block the Android main thread"
        }
        val startedAt = SystemClock.elapsedRealtime()
        val callId = "venera-http-${UUID.randomUUID()}"
        val latch = CountDownLatch(1)
        val value = AtomicReference<Any?>()
        val failure = AtomicReference<Throwable?>()
        mainHandler.post {
            if (closed) {
                failure.set(IllegalStateException("Venera resolver HTTP transport is closed"))
                latch.countDown()
                return@post
            }
            channel.invokeMethod(
                "veneraResolverHttpRequest",
                mapOf(
                    "callId" to callId,
                    "requestId" to requestId,
                    "url" to target.toExternalForm(),
                    "method" to method,
                    "headers" to headers,
                    "body" to bodyBytes,
                    "maxResponseBytes" to maxResponseBytes,
                ),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        value.set(result)
                        latch.countDown()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        failure.set(IllegalStateException("$code: ${message.orEmpty()}"))
                        latch.countDown()
                    }

                    override fun notImplemented() {
                        failure.set(IllegalStateException("Venera resolver rhttp service is unavailable"))
                        latch.countDown()
                    }
                },
            )
        }
        if (!latch.await(VENERA_RESOLVER_RPC_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            cancelCall(callId)
            error("Venera resolver rhttp service timed out")
        }
        failure.get()?.let { throw it }
        val result = value.get() as? Map<*, *>
            ?: error("Venera resolver rhttp result is invalid")
        val status = (result["status"] as? Number)?.toInt()
            ?: error("Venera resolver rhttp status is missing")
        val rawHeaders = result["headers"] as? Map<*, *> ?: emptyMap<Any?, Any?>()
        val responseHeaders = LinkedHashMap<String, List<String>>()
        rawHeaders.forEach { (key, raw) ->
            if (key is String) {
                responseHeaders[key] = when (raw) {
                    is String -> listOf(raw)
                    is List<*> -> raw.filterIsInstance<String>()
                    else -> emptyList()
                }
            }
        }
        val body = when (val raw = result["body"]) {
            is ByteArray -> raw
            is List<*> -> ByteArray(raw.size) { index ->
                (raw[index] as Number).toByte()
            }
            else -> error("Venera resolver rhttp body is missing")
        }
        require(body.size <= maxResponseBytes) {
            "Venera resolver response exceeds $maxResponseBytes bytes"
        }
        if (requestId == null && Log.isLoggable(VENERA_RESOLVER_LOG_TAG, Log.DEBUG)) {
            val totalMs = SystemClock.elapsedRealtime() - startedAt
            val responseVersion = result["version"] ?: "unknown"
            Log.d(
                VENERA_RESOLVER_LOG_TAG,
                "venera-resolver rpc totalMs=$totalMs " +
                    "status=$status bytes=${body.size} " +
                    "version=$responseVersion",
            )
        }
        return VeneraResolverHttpResult(status, responseHeaders, body)
    }

    override fun cancel(requestId: String) {
        if (requestId.isBlank() || closed) return
        mainHandler.post {
            if (!closed) {
                channel.invokeMethod(
                    "veneraResolverHttpCancel",
                    mapOf("requestId" to requestId),
                )
            }
        }
    }

    override fun close() {
        if (closed) return
        val cancelAll = {
            channel.invokeMethod("veneraResolverHttpCancel", emptyMap<String, Any?>())
        }
        if (Looper.myLooper() == Looper.getMainLooper()) cancelAll() else mainHandler.post(cancelAll)
        closed = true
    }

    private fun cancelCall(callId: String) {
        mainHandler.post {
            if (!closed) {
                channel.invokeMethod(
                    "veneraResolverHttpCancel",
                    mapOf("callId" to callId),
                )
            }
        }
    }

    private companion object {
        const val VENERA_RESOLVER_RPC_TIMEOUT_SECONDS = 55L
    }
}
