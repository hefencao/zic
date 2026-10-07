package dev.zic.pluginhost

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Trace
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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CancellationException

internal class PluginRuntimeServiceClient(context: Context) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val packetStore = RuntimeServicePacketStore(appContext)
    private val requestExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-plugin-runtime-request").apply { isDaemon = true }
        }
    private val responseExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-plugin-runtime-response").apply { isDaemon = true }
        }
    private val requestIds = AtomicLong(1L)
    private val pending = LinkedHashMap<Long, PendingCall>()
    private val queued = ArrayDeque<OutgoingRequest>()
    private val bodyClaims = LinkedHashSet<BodyClaim>()
    private var responseWork = 0
    private val replyMessenger = Messenger(ReplyHandler())
    private val serviceIntent = Intent(appContext, ExternalPluginRuntimeService::class.java)
    private val bindingState = RuntimeServiceConnectionState()

    private var serviceMessenger: Messenger? = null
    private var serviceBinder: IBinder? = null
    private var deathRecipient: IBinder.DeathRecipient? = null
    private var connection: ServiceConnection? = null
    private var connectionGeneration: Long? = null
    private var binderGeneration: Long? = null
    private var closing = false
    private var cleanedUp = false

    init {
        requestExecutor.execute { packetStore.clearStaleBodyLeases() }
    }

    fun invoke(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == RuntimeServiceMethodNames.CANCEL ||
            call.method == RuntimeServiceMethodNames.CLOSE_SESSION ||
            call.method == RuntimeServiceMethodNames.CLOSE_PROCESS) {
            val arguments = call.arguments as? Map<*, *>
            bodyClaims.forEach { claim ->
                if (call.method == RuntimeServiceMethodNames.CLOSE_PROCESS ||
                    (claim.processId == arguments?.get("processId") &&
                        claim.sessionId == arguments["sessionId"] &&
                        (call.method == RuntimeServiceMethodNames.CLOSE_SESSION ||
                            claim.requestId == arguments["requestId"]))) {
                    claim.cancelled.set(true)
                }
            }
        }
        if (call.method == RuntimeServiceIpc.CLAIM_BODY_METHOD ||
            call.method == RuntimeServiceIpc.RELEASE_BODY_METHOD ||
            call.method == RuntimeServiceIpc.DISCARD_BODY_METHOD) {
            handleBody(call, result)
            return
        }
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

    private fun handleBody(call: MethodCall, result: MethodChannel.Result) {
        if (cleanedUp || (closing && call.method == RuntimeServiceIpc.CLAIM_BODY_METHOD)) {
            result.error("bridge-closed", "plugin body transport is closing", null)
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val claim = if (call.method == RuntimeServiceIpc.CLAIM_BODY_METHOD) {
            val processId = arguments?.get("processId") as? String
            val sessionId = arguments?.get("sessionId") as? String
            val requestId = arguments?.get("requestId") as? String
            if (processId.isNullOrBlank() || sessionId.isNullOrBlank() || requestId.isNullOrBlank()) {
                result.error("runtime-body-invalid", "body claim binding is missing", null)
                return
            }
            BodyClaim(processId, sessionId, requestId).also(bodyClaims::add)
        } else null
        val reference = if (claim != null) arguments?.get("reference") else call.arguments
        executeResponse {
            val outcome = runCatching {
                when (call.method) {
                    RuntimeServiceIpc.CLAIM_BODY_METHOD -> {
                        require(RuntimeServiceBodyReference.fromMessage(reference).requestId ==
                            requireNotNull(claim).requestId) { "body claim request mismatch" }
                        val tracing = Build.VERSION.SDK_INT >= 29 && Trace.isEnabled()
                        if (tracing) Trace.beginSection("zic.plugin.bodyClaim")
                        try {
                            packetStore.claimBody(reference) {
                                if (claim.cancelled.get()) throw CancellationException()
                            }
                        } finally {
                            if (tracing) Trace.endSection()
                        }
                    }
                    RuntimeServiceIpc.RELEASE_BODY_METHOD -> {
                        packetStore.releaseBody(call.arguments)
                        null
                    }
                    else -> {
                        packetStore.discardBody(call.arguments)
                        null
                    }
                }
            }
            mainHandler.post {
                if (claim != null) bodyClaims.remove(claim)
                if (claim?.cancelled?.get() == true && outcome.isSuccess) {
                    executeResponse {
                        val released = runCatching { packetStore.releaseBody(reference) }
                        mainHandler.post {
                            result.error(
                                "runtime-body-cancelled",
                                released.exceptionOrNull()?.message ?: "body claim was cancelled",
                                null,
                            )
                        }
                    }
                    return@post
                }
                outcome.fold(
                    onSuccess = result::success,
                    onFailure = { error ->
                        result.error(
                            if (error is CancellationException) "runtime-body-cancelled"
                            else "runtime-body-invalid", error.message, null,
                        )
                    },
                )
            }
        }
    }

    fun shutdown() {
        if (closing) {
            return
        }
        closing = true
        bodyClaims.forEach { it.cancelled.set(true) }
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
                "isolated runtime request exceeds logical transport limit",
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
            abandonUnresponsiveBindingIfIdle()
        }
        pending[requestId] = PendingCall(
            requestId = requestId,
            result = result,
            timeout = timeout,
            method = method,
            payload = encoded,
        )
        mainHandler.postDelayed(timeout, RuntimeServiceIpc.REQUEST_TIMEOUT_MILLIS)
        val request = OutgoingRequest(requestId, encoded)
        val messenger = serviceMessenger
        val generation = bindingState.connectedGeneration
        if (messenger == null || generation == null) {
            queued.addLast(request)
            ensureBound()
        } else {
            send(messenger, generation, request)
        }
    }

    private fun ensureBound() {
        if (closing && pending.isEmpty()) {
            return
        }
        val generation = bindingState.beginBinding() ?: return
        val candidate = createConnection(generation)
        connection = candidate
        connectionGeneration = generation
        val accepted = runCatching {
            appContext.bindService(
                serviceIntent,
                candidate,
                Context.BIND_AUTO_CREATE,
            )
        }.getOrDefault(false)
        if (!accepted) {
            handleServiceLoss(
                generation,
                "runtime-service-unavailable",
                "isolated plugin runtime service could not be bound",
            )
        }
    }

    private fun createConnection(generation: Long): ServiceConnection =
        object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                if (!bindingState.markConnected(generation)) {
                    runCatching { appContext.unbindService(this) }
                    return
                }
                val recipient = IBinder.DeathRecipient {
                    mainHandler.post {
                        handleServiceLoss(
                            generation,
                            "runtime-service-died",
                            "isolated plugin runtime service process died",
                        )
                    }
                }
                try {
                    service.linkToDeath(recipient, 0)
                } catch (_: RemoteException) {
                    handleServiceLoss(
                        generation,
                        "runtime-service-died",
                        "isolated plugin runtime service process died",
                    )
                    return
                }
                serviceBinder = service
                deathRecipient = recipient
                binderGeneration = generation
                serviceMessenger = Messenger(service)
                flushQueued(generation)
            }

            override fun onServiceDisconnected(name: ComponentName) {
                handleServiceLoss(
                    generation,
                    "runtime-service-disconnected",
                    "isolated plugin runtime service disconnected",
                )
            }

            override fun onBindingDied(name: ComponentName) {
                handleServiceLoss(
                    generation,
                    "runtime-service-died",
                    "isolated plugin runtime service binding died",
                )
            }

            override fun onNullBinding(name: ComponentName) {
                handleServiceLoss(
                    generation,
                    "runtime-service-unavailable",
                    "isolated plugin runtime service returned no binding",
                )
            }
        }

    private fun flushQueued(generation: Long) {
        val messenger = serviceMessenger ?: return
        if (bindingState.connectedGeneration != generation) {
            return
        }
        while (queued.isNotEmpty()) {
            send(messenger, generation, queued.removeFirst())
        }
    }

    private fun send(
        messenger: Messenger,
        generation: Long,
        request: OutgoingRequest,
    ) {
        if (!pending.containsKey(request.requestId) ||
            bindingState.connectedGeneration != generation
        ) {
            return
        }
        if (request.payload.size <= RuntimeServiceIpc.INLINE_REQUEST_BYTES) {
            sendRequestBundle(
                messenger,
                generation,
                request.requestId,
                Bundle().apply {
                    putByteArray(RuntimeServiceIpc.KEY_INLINE_PAYLOAD, request.payload)
                    putLong(
                        RuntimeServiceIpc.KEY_PAYLOAD_LENGTH,
                        request.payload.size.toLong(),
                    )
                },
            )
            return
        }
        requestExecutor.execute {
            val packet = runCatching { packetStore.writeRequest(request.payload) }
            mainHandler.post {
                packet.fold(
                    onSuccess = { bundle ->
                        if (!pending.containsKey(request.requestId) ||
                            bindingState.connectedGeneration != generation
                        ) {
                            packetStore.delete(bundle)
                            return@fold
                        }
                        sendRequestBundle(
                            messenger,
                            generation,
                            request.requestId,
                            bundle,
                        )
                    },
                    onFailure = { error ->
                        completeError(
                            request.requestId,
                            "runtime-request-invalid",
                            error.message ?: "isolated runtime request packet failed",
                            null,
                        )
                    },
                )
            }
        }
    }

    private fun sendRequestBundle(
        messenger: Messenger,
        generation: Long,
        requestId: Long,
        bundle: Bundle,
    ) {
        if (!pending.containsKey(requestId) ||
            bindingState.connectedGeneration != generation
        ) {
            packetStore.delete(bundle)
            return
        }
        val message = Message.obtain(null, RuntimeServiceIpc.MESSAGE_REQUEST)
        message.replyTo = replyMessenger
        bundle.putLong(RuntimeServiceIpc.KEY_REQUEST_ID, requestId)
        message.data = bundle
        try {
            messenger.send(message)
        } catch (_: RemoteException) {
            packetStore.delete(bundle)
            handleServiceLoss(
                generation,
                "runtime-service-disconnected",
                "isolated plugin runtime service disconnected",
            )
        }
    }

    private fun abandonUnresponsiveBindingIfIdle() {
        if (pending.isNotEmpty() || serviceMessenger != null) {
            return
        }
        val generation = bindingState.activeGeneration ?: return
        if (!bindingState.markLost(generation)) {
            return
        }
        unlinkDeathRecipient(generation)
        safeUnbind(generation)
    }

    private fun handleResponse(message: Message) {
        val requestId = message.data.getLong(RuntimeServiceIpc.KEY_REQUEST_ID, -1L)
        val packet = Bundle(message.data)
        if (cleanedUp && responseWork == 0) {
            packetStore.delete(packet)
            return
        }
        executeResponse {
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
        if (!pending.containsKey(requestId)) {
            executeResponse { packetStore.deleteEnvelopeBody(value) }
            return
        }
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

    private fun handleServiceLoss(
        generation: Long,
        code: String,
        message: String,
    ) {
        if (!bindingState.markLost(generation)) {
            return
        }
        serviceMessenger = null
        unlinkDeathRecipient(generation)
        safeUnbind(generation)
        packetStore.clear()

        // A Binder generation can disappear while the first runtime activation
        // request is in flight. The Android client owns that transport
        // continuity: retain only activation requests across one dead/disconnected
        // service generation and rebind them with the same request payload.
        // Established-session invocations are failed normally so the Dart
        // connection can perform its semantic session recovery; plugin/runtime
        // business errors never enter this path.
        if (replayInitialActivationsAfterServiceLoss(code, message)) {
            ensureBound()
            return
        }
        failAll(code, message)
    }

    private fun replayInitialActivationsAfterServiceLoss(
        code: String,
        message: String,
    ): Boolean {
        queued.clear()
        val failures = mutableListOf<PendingCall>()
        val retained = mutableListOf<OutgoingRequest>()
        val iterator = pending.entries.iterator()
        while (iterator.hasNext()) {
            val (_, call) = iterator.next()
            if (call.canReplayAcrossServiceGenerationLoss(code)) {
                call.serviceGenerationReplays += 1
                retained += OutgoingRequest(call.requestId, call.payload)
            } else {
                iterator.remove()
                mainHandler.removeCallbacks(call.timeout)
                failures += call
            }
        }
        failures.forEach { call -> call.result.error(code, message, null) }
        retained.forEach(queued::addLast)
        return retained.isNotEmpty()
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
        bindingState.close()
        serviceMessenger = null
        queued.clear()
        val generation = connectionGeneration
        if (generation != null) {
            unlinkDeathRecipient(generation)
            safeUnbind(generation)
        }
        appContext.stopService(serviceIntent)
        requestExecutor.shutdownNow()
        finishResponseShutdownIfIdle()
        packetStore.clear()
    }

    // The existing response executor drains admitted IO and its main-thread
    // publication/cleanup callbacks before shutdown; cancellation never drops a result.
    private fun executeResponse(work: () -> Unit) {
        responseWork++
        responseExecutor.execute {
            try {
                work()
            } finally {
                mainHandler.post {
                    responseWork--
                    finishResponseShutdownIfIdle()
                }
            }
        }
    }

    private fun finishResponseShutdownIfIdle() {
        if (cleanedUp && responseWork == 0) responseExecutor.shutdown()
    }

    private class BodyClaim(val processId: String, val sessionId: String, val requestId: String) {
        val cancelled = AtomicBoolean(false)
    }

    private fun unlinkDeathRecipient(generation: Long) {
        if (binderGeneration != generation) {
            return
        }
        val binder = serviceBinder
        val recipient = deathRecipient
        if (binder != null && recipient != null) {
            runCatching { binder.unlinkToDeath(recipient, 0) }
        }
        serviceBinder = null
        deathRecipient = null
        binderGeneration = null
    }

    private fun safeUnbind(generation: Long) {
        if (connectionGeneration != generation) {
            return
        }
        val current = connection
        connection = null
        connectionGeneration = null
        if (current != null) {
            runCatching { appContext.unbindService(current) }
        }
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
        val requestId: Long,
        val result: MethodChannel.Result,
        val timeout: Runnable,
        val method: String,
        val payload: ByteArray,
        var serviceGenerationReplays: Int = 0,
    ) {
        fun canReplayAcrossServiceGenerationLoss(code: String): Boolean =
            RuntimeServiceRequestLifecyclePolicy
                .shouldReplayAcrossServiceGenerationLoss(
                    method = method,
                    code = code,
                    completedReplays = serviceGenerationReplays,
                )
    }

    private data class OutgoingRequest(
        val requestId: Long,
        val payload: ByteArray,
    )
}

private object RuntimeServiceMethodNames {
    const val CANCEL = "cancelExternalRuntime"
    const val CLOSE_SESSION = "closeExternalRuntime"
    const val CLOSE_PROCESS = "closeExternalRuntimeProcess"
}
