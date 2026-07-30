package dev.zic.pluginhost

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

internal class PluginRuntimeServiceClient(context: Context) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val packetStore = RuntimeServicePacketStore(appContext)
    private val responseExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-plugin-runtime-response").apply { isDaemon = true }
        }
    private val requestIds = AtomicLong(1L)
    private val pending = LinkedHashMap<Long, PendingCall>()
    private val queued = ArrayDeque<OutgoingRequest>()
    private val replyMessenger = Messenger(ReplyHandler())
    private val serviceIntent = Intent(appContext, ExternalPluginRuntimeService::class.java)

    private var serviceMessenger: Messenger? = null
    private var binding = false
    private var bound = false
    private var closing = false
    private var cleanedUp = false

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            binding = false
            bound = true
            serviceMessenger = Messenger(service)
            flushQueued()
        }

        override fun onServiceDisconnected(name: ComponentName) {
            handleServiceLoss(
                "runtime-service-disconnected",
                "isolated plugin runtime service disconnected",
            )
        }

        override fun onBindingDied(name: ComponentName) {
            handleServiceLoss(
                "runtime-service-died",
                "isolated plugin runtime service binding died",
            )
        }

        override fun onNullBinding(name: ComponentName) {
            handleServiceLoss(
                "runtime-service-unavailable",
                "isolated plugin runtime service returned no binding",
            )
        }
    }

    fun invoke(call: MethodCall, result: MethodChannel.Result) {
        if (closing) {
            result.error(
                "bridge-closed",
                "plugin runtime bridge is closing",
                null,
            )
            return
        }
        enqueue(call.method, call.arguments, result)
    }

    fun shutdown() {
        if (closing) {
            return
        }
        closing = true
        failAll("bridge-closed", "plugin runtime bridge is closing")
        if (serviceMessenger == null) {
            cleanupBinding()
            return
        }
        val closeResult = object : MethodChannel.Result {
            override fun success(result: Any?) = cleanupBinding()
            override fun error(code: String, message: String?, details: Any?) =
                cleanupBinding()
            override fun notImplemented() = cleanupBinding()
        }
        enqueue(
            RuntimeServiceMethodNames.CLOSE_PROCESS,
            null,
            closeResult,
            allowClosing = true,
        )
        mainHandler.postDelayed(::cleanupBinding, 2_000L)
    }

    private fun enqueue(
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
        allowClosing: Boolean = false,
    ) {
        if (closing && !allowClosing) {
            result.error("bridge-closed", "plugin runtime bridge is closing", null)
            return
        }
        val encoded = runCatching {
            RuntimeServiceWireCodec.encode(
                mapOf("method" to method, "arguments" to arguments),
            )
        }.getOrElse { error ->
            result.error("runtime-request-invalid", error.message, null)
            return
        }
        if (encoded.size > RuntimeServiceIpc.MAX_REQUEST_BYTES) {
            result.error(
                "runtime-request-too-large",
                "isolated runtime request exceeds Binder envelope",
                encoded.size,
            )
            return
        }
        val requestId = requestIds.getAndIncrement()
        lateinit var timeout: Runnable
        timeout = Runnable {
            val call = pending.remove(requestId) ?: return@Runnable
            queued.removeIf { it.requestId == requestId }
            call.result.error(
                "runtime-service-timeout",
                "isolated plugin runtime service did not respond",
                null,
            )
        }
        pending[requestId] = PendingCall(result, timeout)
        mainHandler.postDelayed(timeout, RuntimeServiceIpc.REQUEST_TIMEOUT_MILLIS)
        val request = OutgoingRequest(requestId, encoded)
        val messenger = serviceMessenger
        if (messenger == null) {
            queued.addLast(request)
            ensureBound()
        } else {
            send(messenger, request)
        }
    }

    private fun ensureBound() {
        if (binding || bound || closing && pending.isEmpty()) {
            return
        }
        binding = true
        val accepted = runCatching {
            appContext.bindService(
                serviceIntent,
                connection,
                Context.BIND_AUTO_CREATE,
            )
        }.getOrDefault(false)
        if (!accepted) {
            binding = false
            failAll(
                "runtime-service-unavailable",
                "isolated plugin runtime service could not be bound",
            )
        }
    }

    private fun flushQueued() {
        val messenger = serviceMessenger ?: return
        while (queued.isNotEmpty()) {
            send(messenger, queued.removeFirst())
        }
    }

    private fun send(messenger: Messenger, request: OutgoingRequest) {
        if (!pending.containsKey(request.requestId)) {
            return
        }
        val message = Message.obtain(null, RuntimeServiceIpc.MESSAGE_REQUEST)
        message.replyTo = replyMessenger
        message.data = Bundle().apply {
            putLong(RuntimeServiceIpc.KEY_REQUEST_ID, request.requestId)
            putByteArray(RuntimeServiceIpc.KEY_INLINE_PAYLOAD, request.payload)
            putLong(
                RuntimeServiceIpc.KEY_PAYLOAD_LENGTH,
                request.payload.size.toLong(),
            )
        }
        try {
            messenger.send(message)
        } catch (_: RemoteException) {
            completeError(
                request.requestId,
                "runtime-service-disconnected",
                "isolated plugin runtime service disconnected",
                null,
            )
            handleServiceLoss(
                "runtime-service-disconnected",
                "isolated plugin runtime service disconnected",
            )
        }
    }

    private fun handleResponse(message: Message) {
        val requestId = message.data.getLong(RuntimeServiceIpc.KEY_REQUEST_ID, -1L)
        if (requestId < 0 || !pending.containsKey(requestId)) {
            return
        }
        val packet = Bundle(message.data)
        responseExecutor.execute {
            val decoded = runCatching {
                val bytes = packetStore.read(packet)
                RuntimeServiceWireCodec.decode(bytes)
            }
            mainHandler.post {
                decoded.fold(
                    onSuccess = { value -> completeEnvelope(requestId, value) },
                    onFailure = { error ->
                        completeError(
                            requestId,
                            "runtime-response-invalid",
                            error.message ?: "isolated runtime response is invalid",
                            null,
                        )
                    },
                )
            }
        }
    }

    private fun completeEnvelope(requestId: Long, value: Any?) {
        val envelope = value as? Map<*, *> ?: run {
            completeError(
                requestId,
                "runtime-response-invalid",
                "isolated runtime response envelope is invalid",
                null,
            )
            return
        }
        when (envelope["ok"]) {
            true -> completeSuccess(requestId, envelope["result"])
            false -> completeError(
                requestId,
                envelope["code"] as? String ?: "runtime-service-error",
                envelope["message"] as? String,
                envelope["details"],
            )
            else -> completeError(
                requestId,
                "runtime-response-invalid",
                "isolated runtime response status is invalid",
                null,
            )
        }
    }

    private fun completeSuccess(requestId: Long, value: Any?) {
        takePending(requestId)?.result?.success(value)
    }

    private fun completeError(
        requestId: Long,
        code: String,
        message: String?,
        details: Any?,
    ) {
        takePending(requestId)?.result?.error(code, message, details)
    }

    private fun takePending(requestId: Long): PendingCall? {
        val call = pending.remove(requestId) ?: return null
        mainHandler.removeCallbacks(call.timeout)
        return call
    }

    private fun handleServiceLoss(code: String, message: String) {
        serviceMessenger = null
        binding = false
        safeUnbind()
        failAll(code, message)
    }

    private fun failAll(code: String, message: String) {
        queued.clear()
        val calls = pending.values.toList()
        pending.clear()
        calls.forEach { call ->
            mainHandler.removeCallbacks(call.timeout)
            call.result.error(code, message, null)
        }
    }

    private fun cleanupBinding() {
        if (cleanedUp) {
            return
        }
        cleanedUp = true
        serviceMessenger = null
        queued.clear()
        safeUnbind()
        appContext.stopService(serviceIntent)
        responseExecutor.shutdownNow()
        packetStore.clear()
    }

    private fun safeUnbind() {
        if (!bound && !binding) {
            return
        }
        runCatching { appContext.unbindService(connection) }
        bound = false
        binding = false
    }

    private inner class ReplyHandler : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            if (message.what == RuntimeServiceIpc.MESSAGE_RESPONSE) {
                handleResponse(message)
            } else {
                super.handleMessage(message)
            }
        }
    }

    private data class PendingCall(
        val result: MethodChannel.Result,
        val timeout: Runnable,
    )

    private data class OutgoingRequest(
        val requestId: Long,
        val payload: ByteArray,
    )
}

private object RuntimeServiceMethodNames {
    const val CLOSE_PROCESS = "closeExternalRuntimeProcess"
}
