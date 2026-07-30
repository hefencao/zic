package dev.zic.pluginhost

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// Non-exported Android service hosted in `:zic_plugin_runtime`.
///
/// It owns only FlutterEngine/process bootstrap and Binder-safe transport. The
/// Dart endpoint owns payload verification, drivers, sessions and cancellation.
class ExternalPluginRuntimeService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val responseExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-plugin-runtime-ipc").apply { isDaemon = true }
        }
    private val queued = ArrayDeque<InboundRequest>()
    private val incomingMessenger = Messenger(IncomingHandler())

    private lateinit var packetStore: RuntimeServicePacketStore
    private var engine: FlutterEngine? = null
    private var runtimeChannel: MethodChannel? = null
    private var dartReady = false
    private var closing = false
    private var bootstrapFailure: String? = null

    override fun onCreate() {
        super.onCreate()
        packetStore = RuntimeServicePacketStore(applicationContext)
        packetStore.clear()
        bootstrapEngine()
    }

    override fun onBind(intent: Intent?): IBinder = incomingMessenger.binder

    override fun onUnbind(intent: Intent?): Boolean {
        stopSelf()
        return false
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onDestroy() {
        closing = true
        failQueued(
            "runtime-process-terminated",
            "isolated plugin runtime service terminated",
        )
        runtimeChannel?.setMethodCallHandler(null)
        runtimeChannel = null
        engine?.destroy()
        engine = null
        responseExecutor.shutdownNow()
        packetStore.clear()
        super.onDestroy()
    }

    private fun bootstrapEngine() {
        runCatching {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val flutterEngine = FlutterEngine(applicationContext, null, false)
            val channel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                RUNTIME_CHANNEL_NAME,
            )
            channel.setMethodCallHandler { call, result ->
                if (call.method == RUNTIME_READY_METHOD) {
                    val message = call.arguments as? Map<*, *>
                    val processId = message?.get("processId") as? String
                    if (processId.isNullOrBlank()) {
                        result.error(
                            "runtime-request-invalid",
                            "runtime service generation is missing",
                            null,
                        )
                    } else {
                        dartReady = true
                        result.success(null)
                        flushQueued()
                    }
                } else {
                    result.notImplemented()
                }
            }
            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                DART_LIBRARY_URI,
                DART_ENTRYPOINT,
            )
            engine = flutterEngine
            runtimeChannel = channel
            flutterEngine.dartExecutor.executeDartEntrypoint(entrypoint)
        }.onFailure { error ->
            bootstrapFailure = error.message ?: error.javaClass.name
            failQueued(
                "runtime-service-bootstrap-failed",
                "isolated plugin runtime FlutterEngine could not start",
            )
        }
    }

    private fun accept(message: Message) {
        val replyTo = message.replyTo ?: return
        val requestId = message.data.getLong(RuntimeServiceIpc.KEY_REQUEST_ID, -1L)
        if (requestId < 0) {
            return
        }
        val payload = message.data.getByteArray(RuntimeServiceIpc.KEY_INLINE_PAYLOAD)
        val declaredLength = message.data.getLong(
            RuntimeServiceIpc.KEY_PAYLOAD_LENGTH,
            -1L,
        )
        if (payload == null ||
            payload.size > RuntimeServiceIpc.MAX_REQUEST_BYTES ||
            declaredLength != payload.size.toLong()
        ) {
            replyError(
                requestId,
                replyTo,
                "runtime-request-invalid",
                "isolated runtime Binder request is invalid",
                null,
            )
            return
        }
        val request = InboundRequest(requestId, payload, replyTo)
        val failure = bootstrapFailure
        when {
            closing -> replyError(
                requestId,
                replyTo,
                "runtime-process-closing",
                "isolated plugin runtime service is closing",
                null,
            )
            failure != null -> replyError(
                requestId,
                replyTo,
                "runtime-service-bootstrap-failed",
                failure,
                null,
            )
            !dartReady -> {
                if (queued.size >= MAX_QUEUED_REQUESTS) {
                    replyError(
                        requestId,
                        replyTo,
                        "runtime-service-busy",
                        "isolated runtime bootstrap queue is full",
                        null,
                    )
                } else {
                    queued.addLast(request)
                }
            }
            else -> dispatch(request)
        }
    }

    private fun flushQueued() {
        while (dartReady && !closing && queued.isNotEmpty()) {
            dispatch(queued.removeFirst())
        }
    }

    private fun dispatch(request: InboundRequest) {
        val decoded = runCatching {
            RuntimeServiceWireCodec.decode(request.payload) as? Map<*, *>
                ?: error("runtime request envelope is not an object")
        }.getOrElse { error ->
            replyError(
                request.requestId,
                request.replyTo,
                "runtime-request-invalid",
                error.message,
                null,
            )
            return
        }
        val method = decoded["method"] as? String
        if (method.isNullOrBlank()) {
            replyError(
                request.requestId,
                request.replyTo,
                "runtime-request-invalid",
                "runtime request method is missing",
                null,
            )
            return
        }
        val channel = runtimeChannel
        if (channel == null || !dartReady) {
            replyError(
                request.requestId,
                request.replyTo,
                "runtime-service-bootstrap-failed",
                "runtime Dart endpoint is unavailable",
                null,
            )
            return
        }
        channel.invokeMethod(
            method,
            decoded["arguments"],
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    replyEnvelope(
                        request,
                        mapOf("ok" to true, "result" to result),
                        closeAfterReply = method == CLOSE_PROCESS_METHOD,
                    )
                }

                override fun error(code: String, message: String?, details: Any?) {
                    replyEnvelope(
                        request,
                        mapOf(
                            "ok" to false,
                            "code" to code,
                            "message" to message,
                            "details" to details,
                        ),
                    )
                }

                override fun notImplemented() {
                    replyError(
                        request.requestId,
                        request.replyTo,
                        "runtime-method-unsupported",
                        "runtime Dart endpoint did not implement $method",
                        null,
                    )
                }
            },
        )
    }

    private fun replyError(
        requestId: Long,
        replyTo: Messenger,
        code: String,
        message: String?,
        details: Any?,
    ) {
        replyEnvelope(
            InboundRequest(requestId, ByteArray(0), replyTo),
            mapOf(
                "ok" to false,
                "code" to code,
                "message" to message,
                "details" to details,
            ),
        )
    }

    private fun replyEnvelope(
        request: InboundRequest,
        envelope: Map<String, Any?>,
        closeAfterReply: Boolean = false,
    ) {
        responseExecutor.execute {
            val packet = runCatching {
                packetStore.writeResponse(RuntimeServiceWireCodec.encode(envelope))
            }
            mainHandler.post {
                packet.fold(
                    onSuccess = { bundle ->
                        val response = Message.obtain(
                            null,
                            RuntimeServiceIpc.MESSAGE_RESPONSE,
                        )
                        bundle.putLong(
                            RuntimeServiceIpc.KEY_REQUEST_ID,
                            request.requestId,
                        )
                        response.data = bundle
                        runCatching { request.replyTo.send(response) }
                        if (bundle.getString(RuntimeServiceIpc.KEY_PAYLOAD_PATH) != null) {
                            val retainedPacket = Bundle(bundle)
                            mainHandler.postDelayed(
                                { packetStore.delete(retainedPacket) },
                                PACKET_RETENTION_MILLIS,
                            )
                        }
                    },
                    onFailure = {
                        val response = Message.obtain(
                            null,
                            RuntimeServiceIpc.MESSAGE_RESPONSE,
                        )
                        val fallback = RuntimeServiceWireCodec.encode(
                            mapOf(
                                "ok" to false,
                                "code" to "runtime-response-invalid",
                                "message" to "runtime response could not be encoded",
                                "details" to null,
                            ),
                        )
                        response.data = Bundle().apply {
                            putLong(
                                RuntimeServiceIpc.KEY_REQUEST_ID,
                                request.requestId,
                            )
                            putByteArray(
                                RuntimeServiceIpc.KEY_INLINE_PAYLOAD,
                                fallback,
                            )
                            putLong(
                                RuntimeServiceIpc.KEY_PAYLOAD_LENGTH,
                                fallback.size.toLong(),
                            )
                        }
                        runCatching { request.replyTo.send(response) }
                    },
                )
                if (closeAfterReply) {
                    closing = true
                    stopSelf()
                }
            }
        }
    }

    private fun failQueued(code: String, message: String) {
        while (queued.isNotEmpty()) {
            val request = queued.removeFirst()
            replyError(request.requestId, request.replyTo, code, message, null)
        }
    }

    private inner class IncomingHandler : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            if (message.what == RuntimeServiceIpc.MESSAGE_REQUEST) {
                accept(message)
            } else {
                super.handleMessage(message)
            }
        }
    }

    private data class InboundRequest(
        val requestId: Long,
        val payload: ByteArray,
        val replyTo: Messenger,
    )

    companion object {
        private const val RUNTIME_CHANNEL_NAME =
            "dev.zic/plugin_host_runtime_bridge"
        private const val RUNTIME_READY_METHOD = "runtimeServiceReady"
        private const val CLOSE_PROCESS_METHOD = "closeExternalRuntimeProcess"
        private const val DART_LIBRARY_URI =
            "package:zic/main.dart"
        private const val DART_ENTRYPOINT =
            "zicExternalPluginRuntimeServiceMain"
        private const val MAX_QUEUED_REQUESTS = 64
        private const val PACKET_RETENTION_MILLIS = 2 * 60 * 1000L
    }
}
