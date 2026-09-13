package dev.zic.texture

import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.IdentityHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

internal object NativeBlitter {
    init {
        System.loadLibrary("media_core")
    }

    @JvmStatic
    external fun retain(frameAddress: Long): Long

    @JvmStatic
    external fun release(frameAddress: Long)

    @JvmStatic
    external fun prepare(surface: Surface, width: Int, height: Int): Int

    @JvmStatic
    external fun blit(surface: Surface, frameAddress: Long): Int
}

class TextureBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val outputs = mutableMapOf<Long, Output>()
    private val lifecycleLock = Any()
    private val scheduleLock = Any()
    private val pendingSchedules = ArrayList<PendingProducerSchedule>()
    // scheduleFrame() remains effective until the compositor reaches the next
    // vsync. Keep this per producer: one gallery page must not suppress a
    // different page's first schedule, while repeated presents for the same
    // page can share the already queued platform frame.
    private val scheduledProducers = IdentityHashMap<
        TextureRegistry.SurfaceProducer,
        Boolean,
    >()
    private val scheduleBoundaryCallback =
        Choreographer.FrameCallback { onScheduleBoundary() }
    private val detached = AtomicBoolean(true)
    private var queuedBytes = AtomicLong(0)

    @Volatile
    private var schedulePosted = false

    @Volatile
    private var scheduleBoundaryPosted = false

    private var blitLanes: List<ExecutorService> = emptyList()
    private var scheduleCompletionExecutor: ExecutorService? = null
    private val nextBlitLane = AtomicInteger(0)
    private lateinit var textures: TextureRegistry
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(lifecycleLock) { detached.set(false) }
        synchronized(scheduleLock) {
            schedulePosted = false
            scheduleBoundaryPosted = false
            pendingSchedules.clear()
            scheduledProducers.clear()
        }
        queuedBytes = AtomicLong(0)
        nextBlitLane.set(0)
        blitLanes = List(BLIT_LANE_COUNT, ::newBlitLane)
        scheduleCompletionExecutor = newScheduleCompletionExecutor()
        blitLanes.forEach { lane -> lane.execute {} }
        textures = binding.textureRegistry
        channel = MethodChannel(
            binding.binaryMessenger,
            CHANNEL_NAME,
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(lifecycleLock) { detached.set(true) }
        synchronized(scheduleLock) {
            scheduleBoundaryPosted = false
            scheduledProducers.clear()
        }
        removeScheduleBoundaryCallback()
        failPendingSchedules(
            IllegalStateException("texture bridge is detached"),
        )
        channel.setMethodCallHandler(null)
        val owned = synchronized(outputs) {
            outputs.values.toList().also { outputs.clear() }
        }
        val lanes = blitLanes
        blitLanes = emptyList()
        val completionExecutor = scheduleCompletionExecutor
        scheduleCompletionExecutor = null
        for (output in owned) {
            try {
                output.lane.execute(output::release)
            } catch (_: RejectedExecutionException) {
                output.release()
            }
        }
        lanes.forEach(ExecutorService::shutdown)
        completionExecutor?.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> create(call, result)
            "initialize" -> initialize(call, result)
            "resize" -> resize(call, result)
            "present" -> present(call, result)
            "redraw" -> redraw(call, result)
            "release" -> release(call, result)
            else -> result.notImplemented()
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val output = output(call, result) ?: return
        val lane = lane(output, result) ?: return
        try {
            lane.execute {
                try {
                    // SurfaceProducer#getSurface() lazily creates the
                    // ImageReader/Surface. Keep that materialization on the
                    // serialized blit lane so the first visible present does
                    // not pay the initialization cost on the UI path.
                    output.initialize()
                    success(result, null)
                } catch (error: Throwable) {
                    error(
                        result,
                        "initialize_failed",
                        error.message ?: error.toString(),
                    )
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("detached", "texture blit lane is unavailable", null)
        }
    }

    private fun create(call: MethodCall, result: MethodChannel.Result) {
        val width = call.intArgument("width")
        val height = call.intArgument("height")
        if (width == null || height == null || width <= 0 || height <= 0) {
            result.error(
                "invalid_dimensions",
                "positive width and height are required",
                null,
            )
            return
        }
        val lane = nextLane(result) ?: return
        runOnMain(result) {
            if (detached.get()) {
                result.error("detached", "texture bridge is detached", null)
                return@runOnMain
            }
            val producer = textures.createSurfaceProducer()
            producer.setSize(width, height)
            val completionExecutor = scheduleCompletionExecutor
            if (completionExecutor == null) {
                try {
                    producer.release()
                } catch (_: Throwable) {
                    // Detach owns final cleanup when the engine races create.
                }
                result.error("detached", "texture bridge is detached", null)
                return@runOnMain
            }
            lateinit var output: Output
            output = Output(
                lane = lane,
                producer = producer,
                width = width,
                height = height,
                canPresent = { !detached.get() },
                scheduleFrame = { complete ->
                    scheduleProducerFrame(
                        producer,
                        canSchedule = { !output.isReleased },
                        completionExecutor = completionExecutor,
                        complete = complete,
                    )
                },
                scheduleRedraw = { target -> scheduleRedraw(target) },
                resizeProducer = { nextWidth, nextHeight ->
                    // Output.resize() already runs on its serialized blit
                    // lane. SurfaceProducer#setSize only changes the
                    // producer's requested geometry and has no main-looper
                    // requirement; keeping it here avoids a resize/use race
                    // and an extra UI message during a page transition.
                    if (!output.isReleased && !detached.get()) {
                        producer.setSize(nextWidth, nextHeight)
                    }
                },
                releaseProducer = {
                    // SurfaceTextureSurfaceProducer (the API < 29 fallback)
                    // expects a Surface to have been materialized before
                    // release(); create it only for an output that was never
                    // presented so an idle prewarm can still be retired
                    // safely.
                    if (!output.hasInitializedSurface) {
                        try {
                            producer.surface
                        } catch (_: Throwable) {
                            // The surface may already be in cleanup. The
                            // producer release below remains authoritative.
                        }
                    }
                    // Flutter's unregisterTexture() is a UI-thread JNI API;
                    // retain that lifecycle boundary even though the surface
                    // materialization above stays off the UI lane.
                    mainHandler.post {
                        producer.setCallback(null)
                        try {
                            producer.release()
                        } catch (_: Throwable) {
                            // Keep the release MethodChannel call settle even
                            // if an already-invalid SurfaceProducer rejects
                            // cleanup.
                        }
                    }
                },
            )
            synchronized(outputs) { outputs[producer.id()] = output }
            result.success(mapOf("textureId" to producer.id()))
        }
    }

    private fun resize(call: MethodCall, result: MethodChannel.Result) {
        val output = output(call, result) ?: return
        val width = call.intArgument("width")
        val height = call.intArgument("height")
        if (width == null || height == null || width <= 0 || height <= 0) {
            result.error(
                "invalid_dimensions",
                "positive width and height are required",
                null,
            )
            return
        }
        val lane = lane(output, result) ?: return
        try {
            lane.execute {
                try {
                    output.resize(width, height)
                    success(result, null)
                } catch (error: Throwable) {
                    error(result, "resize_failed", error.message ?: error.toString())
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("detached", "texture blit lane is unavailable", null)
        }
    }

    private fun redraw(call: MethodCall, result: MethodChannel.Result) {
        val output = output(call, result) ?: return
        val lane = lane(output, result) ?: return
        try {
            lane.execute {
                try {
                    output.redraw()
                    success(result, null)
                } catch (error: Throwable) {
                    error(
                        result,
                        "redraw_failed",
                        error.message ?: error.toString(),
                    )
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("detached", "texture blit lane is unavailable", null)
        }
    }

    private fun present(call: MethodCall, result: MethodChannel.Result) {
        val output = output(call, result) ?: return
        val frameAddress = call.longArgument("frameHandle")
        val frameBytes = maxOf(0L, call.longArgument("frameBytes") ?: 0L)
        val deadlineAfterMicros = call.longArgument("deadlineAfterMicros")
        if (frameAddress == null || frameAddress == 0L) {
            result.error(
                "invalid_frame",
                "a retained native frame handle is required",
                null,
            )
            return
        }
        if (deadlineAfterMicros != null && deadlineAfterMicros < 0L) {
            result.error("invalid_deadline", "deadline must be non-negative", null)
            return
        }
        val lane = lane(output, result) ?: return
        val submittedNanos = System.nanoTime()
        val queue = queuedBytes
        queue.addAndGet(frameBytes)
        try {
            lane.execute {
                val startedNanos = System.nanoTime()
                val replied = AtomicBoolean(false)
                fun complete(presentation: PresentResult?, failure: Throwable? = null) {
                    if (!replied.compareAndSet(false, true)) return
                    try {
                        val finishedNanos = System.nanoTime()
                        if (failure != null) {
                            error(
                                result,
                                "blit_failed",
                                failure.message ?: failure.toString(),
                            )
                            return
                        }
                        check(presentation != null)
                        if (presentation.failure != null) {
                            error(
                                result,
                                "schedule_failed",
                                presentation.failure.message
                                    ?: presentation.failure.toString(),
                            )
                            return
                        }
                        if (presentation.status != 0) {
                            error(
                                result,
                                "blit_failed",
                                "native blit failed with status ${presentation.status}",
                            )
                            return
                        }
                        val elapsedMicros =
                            (finishedNanos - submittedNanos) / 1_000L
                        val otherQueuedBytes = maxOf(0L, queue.get() - frameBytes)
                        val response = mapOf(
                            "queueMicros" to
                                (startedNanos - submittedNanos) / 1_000L,
                            "uploadMicros" to
                                (finishedNanos - startedNanos) / 1_000L,
                            "retainMicros" to presentation.retainMicros,
                            "blitMicros" to presentation.blitMicros,
                            "surfaceReconfigureCount" to
                                presentation.surfaceReconfigureCount,
                            "scheduleMicros" to presentation.scheduleMicros,
                            "scheduleQueueMicros" to
                                presentation.scheduleQueueMicros,
                            "scheduleCallMicros" to
                                presentation.scheduleCallMicros,
                            "replaceMicros" to presentation.replaceMicros,
                            "deadlineMissMicros" to
                                if (deadlineAfterMicros == null) {
                                    0L
                                } else {
                                    maxOf(0L, elapsedMicros - deadlineAfterMicros)
                                },
                            "textureBytes" to output.textureBytes,
                            "inFlightBytes" to
                                output.retainedFrameBytes + otherQueuedBytes,
                            // scheduleFrame() has already run on the platform
                            // thread; the completion itself is dispatched back
                            // to the blit lane so this response cannot extend a
                            // Flutter UI turn.
                            "resultDispatchMicros" to 0L,
                        )
                        success(result, response)
                    } catch (error: Throwable) {
                        error(
                            result,
                            "blit_failed",
                            error.message ?: error.toString(),
                        )
                    } finally {
                        queue.addAndGet(-frameBytes)
                    }
                }
                try {
                    output.present(frameAddress, frameBytes) { presentation ->
                        complete(presentation)
                    }
                } catch (error: Throwable) {
                    complete(null, error)
                }
            }
        } catch (_: RejectedExecutionException) {
            queue.addAndGet(-frameBytes)
            result.error("detached", "texture blit lane is unavailable", null)
        }
    }

    private fun release(call: MethodCall, result: MethodChannel.Result) {
        val textureId = call.longArgument("textureId")
        if (textureId == null) {
            result.error("invalid_texture", "textureId is required", null)
            return
        }
        val output = synchronized(outputs) { outputs.remove(textureId) }
        if (output == null) {
            result.success(null)
            return
        }
        val lane = lane(output, result) ?: run {
            output.release()
            return
        }
        try {
            lane.execute {
                output.release()
                success(result, null)
            }
        } catch (_: RejectedExecutionException) {
            output.release()
            result.error("detached", "texture blit lane is unavailable", null)
        }
    }

    private fun output(call: MethodCall, result: MethodChannel.Result): Output? {
        val textureId = call.longArgument("textureId")
        val output = textureId?.let { synchronized(outputs) { outputs[it] } }
        if (output == null) {
            result.error("unknown_texture", "texture is not active", null)
        }
        return output
    }

    private fun nextLane(result: MethodChannel.Result): ExecutorService? {
        val lanes = blitLanes
        if (lanes.isEmpty() || detached.get()) {
            result.error("detached", "texture bridge is detached", null)
            return null
        }
        val index = Math.floorMod(nextBlitLane.getAndIncrement(), lanes.size)
        return lanes[index]
    }

    private fun lane(
        output: Output,
        result: MethodChannel.Result,
    ): ExecutorService? {
        if (detached.get()) {
            result.error("detached", "texture bridge is detached", null)
            return null
        }
        return output.lane
    }

    private fun scheduleProducerFrame(
        producer: TextureRegistry.SurfaceProducer,
        canSchedule: () -> Boolean,
        completionExecutor: ExecutorService,
        complete: (ScheduleResult) -> Unit,
    ): Boolean {
        val submittedNanos = System.nanoTime()
        val request = PendingProducerSchedule(
            producer = producer,
            canSchedule = canSchedule,
            submittedNanos = submittedNanos,
            completionExecutor = completionExecutor,
            complete = complete,
        )
        var immediateResult: ScheduleResult? = null
        var coveredByVsyncSchedule = false
        val shouldPost: Boolean
        synchronized(scheduleLock) {
            if (detached.get()) {
                immediateResult = ScheduleResult(
                    scheduled = false,
                    failure = IllegalStateException(
                        "texture bridge is detached",
                    ),
                )
                shouldPost = false
            } else if (scheduledProducers.containsKey(producer)) {
                // The previous schedule will expose the newest resident
                // surface contents at this vsync. Complete this waiter off
                // the platform thread without queueing another Handler turn.
                coveredByVsyncSchedule = true
                shouldPost = false
            } else {
                pendingSchedules += request
                shouldPost = !schedulePosted
                schedulePosted = true
            }
        }
        val result = immediateResult
        if (result != null) {
            dispatchScheduleCompletion(request, result)
            return false
        }
        if (coveredByVsyncSchedule) {
            dispatchScheduleCompletion(
                request,
                ScheduleResult(
                    scheduled = true,
                    queueMicros = (System.nanoTime() - submittedNanos) / 1_000L,
                ),
            )
            return true
        }
        if (!shouldPost) {
            // All outputs share one main-looper handoff. Output-local
            // coalescing still guarantees at most one request per producer in
            // this batch; this boundary prevents four adjacent gallery pages
            // from queueing four independent Handler messages behind a
            // Flutter frame.
            return true
        }
        if (Looper.myLooper() == mainHandler.looper) {
            drainProducerSchedules()
            return true
        }
        if (mainHandler.post(::drainProducerSchedules)) {
            return true
        }
        failPendingSchedules(
            IllegalStateException("platform thread is unavailable"),
        )
        return false
    }

    private fun drainProducerSchedules() {
        val pending = synchronized(scheduleLock) {
            schedulePosted = false
            pendingSchedules.toList().also { pendingSchedules.clear() }
        }
        if (pending.isEmpty()) return

        val drainedAtNanos = System.nanoTime()
        val results = ArrayList<Pair<PendingProducerSchedule, ScheduleResult>>(
            pending.size,
        )
        var scheduledAny = false
        synchronized(lifecycleLock) {
            for (request in pending) {
                val queueMicros =
                    (drainedAtNanos - request.submittedNanos) / 1_000L
                val result = try {
                    val alreadyScheduled = synchronized(scheduleLock) {
                        scheduledProducers.containsKey(request.producer)
                    }
                    if (detached.get() || !request.canSchedule()) {
                        ScheduleResult(
                            scheduled = false,
                            queueMicros = queueMicros,
                        )
                    } else if (alreadyScheduled) {
                        ScheduleResult(
                            scheduled = true,
                            queueMicros = queueMicros,
                        )
                    } else {
                        val callStartedNanos = System.nanoTime()
                        request.producer.scheduleFrame()
                        synchronized(scheduleLock) {
                            scheduledProducers[request.producer] = true
                        }
                        scheduledAny = true
                        ScheduleResult(
                            scheduled = true,
                            queueMicros = queueMicros,
                            callMicros =
                                (System.nanoTime() - callStartedNanos) / 1_000L,
                        )
                    }
                } catch (error: Throwable) {
                    ScheduleResult(
                        scheduled = false,
                        queueMicros = queueMicros,
                        failure = error,
                    )
                }
                results += request to result
            }
        }
        for ((request, result) in results) {
            dispatchScheduleCompletion(request, result)
        }
        if (scheduledAny) {
            postScheduleBoundary()
        }
    }

    private fun postScheduleBoundary() {
        val shouldPost = synchronized(scheduleLock) {
            if (detached.get() || scheduleBoundaryPosted) {
                false
            } else {
                scheduleBoundaryPosted = true
                true
            }
        }
        if (!shouldPost) return
        try {
            Choreographer.getInstance().postFrameCallback(scheduleBoundaryCallback)
        } catch (_: Throwable) {
            // A platform teardown can race the drain. Do not leave a producer
            // permanently coalesced if Choreographer is no longer available.
            synchronized(scheduleLock) {
                scheduleBoundaryPosted = false
                scheduledProducers.clear()
            }
        }
    }

    private fun onScheduleBoundary() {
        synchronized(scheduleLock) {
            scheduleBoundaryPosted = false
            scheduledProducers.clear()
        }
    }

    private fun removeScheduleBoundaryCallback() {
        val remove = {
            try {
                Choreographer.getInstance().removeFrameCallback(
                    scheduleBoundaryCallback,
                )
            } catch (_: Throwable) {
                // Detach remains authoritative even if the engine has already
                // torn down the platform looper.
            }
        }
        if (Looper.myLooper() == mainHandler.looper) {
            remove()
        } else {
            mainHandler.post(remove)
        }
    }

    private fun failPendingSchedules(error: Throwable) {
        val pending = synchronized(scheduleLock) {
            schedulePosted = false
            pendingSchedules.toList().also { pendingSchedules.clear() }
        }
        if (pending.isEmpty()) return
        val failure = ScheduleResult(scheduled = false, failure = error)
        for (request in pending) {
            dispatchScheduleCompletion(request, failure)
        }
    }

    /**
     * SurfaceProducer.scheduleFrame() must be handed off on the Android main
     * looper, but completing the originating MethodChannel call does not. The
     * old implementation completed every waiter in the same main-looper
     * runnable as scheduleFrame(). With several gallery outputs that made a
     * burst of codec/upload acknowledgements part of the UI-critical turn.
     * Return the result on the blit lane instead; MethodChannel.Result is
     * explicitly thread-safe and the native resident frame is already posted.
     */
    private fun dispatchScheduleCompletion(
        request: PendingProducerSchedule,
        result: ScheduleResult,
    ) {
        try {
            request.completionExecutor.execute {
                request.complete(result)
            }
        } catch (_: RejectedExecutionException) {
            // Detach can race lane shutdown. A rejected completion must still
            // settle the pending Dart call exactly once.
            request.complete(result)
        }
    }

    private fun scheduleRedraw(output: Output) {
        try {
            output.lane.execute { output.redraw() }
        } catch (_: RejectedExecutionException) {
            // Detach or shutdown owns final cleanup.
        }
    }

    private fun runOnMain(
        result: MethodChannel.Result,
        action: () -> Unit,
    ) {
        if (Looper.myLooper() == mainHandler.looper) {
            try {
                action()
            } catch (error: Throwable) {
                result.error("platform_failure", error.message ?: error.toString(), null)
            }
            return
        }
        if (!mainHandler.post {
                try {
                    action()
                } catch (error: Throwable) {
                    result.error(
                        "platform_failure",
                        error.message ?: error.toString(),
                        null,
                    )
                }
            }
        ) {
            result.error("detached", "platform thread is unavailable", null)
        }
    }

    private fun success(result: MethodChannel.Result, value: Any?) {
        // MethodChannel.Result methods may be invoked from any thread. Keep
        // blit-lane completions off the Android UI looper so an acknowledgement
        // cannot extend a Flutter frame's platform turn.
        result.success(value)
    }

    private fun error(result: MethodChannel.Result, code: String, message: String) {
        result.error(code, message, null)
    }

    private data class ScheduleResult(
        val scheduled: Boolean,
        val queueMicros: Long = 0L,
        val callMicros: Long = 0L,
        val failure: Throwable? = null,
    ) {
        val totalMicros: Long
            get() = queueMicros + callMicros
    }

    private data class PresentResult(
        val status: Int,
        val retainMicros: Long,
        val blitMicros: Long,
        val surfaceReconfigureCount: Int,
        val scheduleMicros: Long,
        val scheduleQueueMicros: Long,
        val scheduleCallMicros: Long,
        val replaceMicros: Long,
        val failure: Throwable? = null,
    )

    private data class PendingProducerSchedule(
        val producer: TextureRegistry.SurfaceProducer,
        val canSchedule: () -> Boolean,
        val submittedNanos: Long,
        val completionExecutor: ExecutorService,
        val complete: (ScheduleResult) -> Unit,
    )

    private data class BlitResult(
        val status: Int,
        val blitMicros: Long,
        val surfaceReconfigureCount: Int,
    )

    @Suppress("DEPRECATION")
    private class Output(
        val lane: ExecutorService,
        private val producer: TextureRegistry.SurfaceProducer,
        private var width: Int,
        private var height: Int,
        private val canPresent: () -> Boolean,
        private val scheduleFrame: ((ScheduleResult) -> Unit) -> Boolean,
        private val scheduleRedraw: (Output) -> Unit,
        private val resizeProducer: (Int, Int) -> Unit,
        private val releaseProducer: () -> Unit,
    ) {
        private val scheduleLock = Any()
        private val pendingSchedules = ArrayList<ScheduleWaiter>()

        @Volatile
        private var schedulePosted = false

        @Volatile
        private var surfaceAvailable = true

        @Volatile
        private var surfaceInitialized = false

        @Volatile
        private var released = false

        private var currentFrameAddress = 0L
        private var currentFrameBytes = 0L

        init {
            producer.setCallback(
                object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        surfaceAvailable = true
                        scheduleRedraw(this@Output)
                    }

                    override fun onSurfaceCleanup() {
                        surfaceAvailable = false
                    }
                },
            )
        }

        val isReleased: Boolean
            get() = released

        val hasInitializedSurface: Boolean
            get() = surfaceInitialized

        val textureBytes: Long
            get() = width.toLong() * height.toLong() * 4L

        val retainedFrameBytes: Long
            get() = currentFrameBytes

        fun present(
            frameAddress: Long,
            frameBytes: Long,
            complete: (PresentResult) -> Unit,
        ) {
            check(!released) { "texture output is released" }
            check(canPresent()) { "texture bridge is detached" }
            val retainStartedNanos = System.nanoTime()
            val retained = NativeBlitter.retain(frameAddress)
            val retainFinishedNanos = System.nanoTime()
            check(retained != 0L) { "native frame retain failed" }
            try {
                val blit = blitConfigured(retained)
                val retainMicros =
                    (retainFinishedNanos - retainStartedNanos) / 1_000L
                if (blit.status != 0) {
                    complete(
                        PresentResult(
                            status = blit.status,
                            retainMicros = retainMicros,
                            blitMicros = blit.blitMicros,
                            surfaceReconfigureCount = blit.surfaceReconfigureCount,
                            scheduleMicros = 0L,
                            scheduleQueueMicros = 0L,
                            scheduleCallMicros = 0L,
                            replaceMicros = 0L,
                        ),
                    )
                    return
                }
                val replaceStartedNanos = System.nanoTime()
                replaceCurrentFrame(retained, frameBytes)
                val replaceMicros =
                    (System.nanoTime() - replaceStartedNanos) / 1_000L
                requestSchedule { schedule ->
                    complete(
                        PresentResult(
                            status = if (schedule.scheduled) 0 else -1,
                            retainMicros = retainMicros,
                            blitMicros = blit.blitMicros,
                            surfaceReconfigureCount = blit.surfaceReconfigureCount,
                            scheduleMicros = schedule.totalMicros,
                            scheduleQueueMicros = schedule.queueMicros,
                            scheduleCallMicros = schedule.callMicros,
                            replaceMicros = replaceMicros,
                            failure = schedule.failure,
                        ),
                    )
                }
            } finally {
                if (currentFrameAddress != retained) {
                    NativeBlitter.release(retained)
                }
            }
        }

        fun initialize() {
            check(!released) { "texture output is released" }
            check(surfaceAvailable) { "SurfaceProducer surface is unavailable" }
            check(canPresent()) { "texture bridge is detached" }
            val status = NativeBlitter.prepare(surface(), width, height)
            check(status == BLIT_OK) {
                "native texture prepare failed with status $status"
            }
        }

        fun redraw() {
            if (
                released ||
                !surfaceAvailable ||
                !canPresent() ||
                currentFrameAddress == 0L
            ) {
                return
            }
            if (blitConfigured(currentFrameAddress).status == 0) {
                requestSchedule { _ -> }
            }
        }

        /**
         * Coalesces scheduleFrame() requests while the Android main looper is
         * busy with a Flutter frame. The native surface already contains the
         * newest frame after [present] returns, so one schedule call is enough
         * for all frames submitted before that main-thread handoff. Every
         * caller still receives a completion, preserving the MethodChannel
         * ownership boundary without queueing one main-looper runnable per
         * animation frame.
         */
        private fun requestSchedule(
            complete: (ScheduleResult) -> Unit,
        ): Boolean {
            val waiter = ScheduleWaiter(System.nanoTime(), complete)
            var rejected = false
            val shouldPost = synchronized(scheduleLock) {
                if (released) {
                    rejected = true
                    false
                } else {
                    pendingSchedules += waiter
                    if (schedulePosted) {
                        false
                    } else {
                        schedulePosted = true
                        true
                    }
                }
            }
            if (rejected) {
                complete(
                    ScheduleResult(
                        scheduled = false,
                        failure = IllegalStateException(
                            "texture output is released",
                        ),
                    ),
                )
                return false
            }
            if (!shouldPost) {
                // A schedule runnable is already queued. Its completion will
                // cover this waiter after the newest resident frame wins.
                return true
            }

            val accepted = scheduleFrame { schedule ->
                val now = System.nanoTime()
                val waiters = synchronized(scheduleLock) {
                    schedulePosted = false
                    pendingSchedules.toList().also { pendingSchedules.clear() }
                }
                for (pending in waiters) {
                    val queueMicros = maxOf(
                        schedule.queueMicros,
                        (now - pending.submittedNanos) / 1_000L,
                    )
                    pending.complete(schedule.copy(queueMicros = queueMicros))
                }
            }
            if (!accepted) {
                val waiters = synchronized(scheduleLock) {
                    schedulePosted = false
                    pendingSchedules.toList().also { pendingSchedules.clear() }
                }
                val failure = ScheduleResult(
                    scheduled = false,
                    failure = IllegalStateException(
                        "texture schedule queue is unavailable",
                    ),
                )
                for (pending in waiters) {
                    pending.complete(failure)
                }
            }
            return accepted
        }

        fun resize(width: Int, height: Int) {
            check(!released) { "texture output is released" }
            if (this.width == width && this.height == height) return
            clearCurrentFrame()
            resizeProducer(width, height)
            this.width = width
            this.height = height
        }

        fun release() {
            if (released) {
                return
            }
            released = true
            surfaceAvailable = false
            val waiters = synchronized(scheduleLock) {
                schedulePosted = false
                pendingSchedules.toList().also { pendingSchedules.clear() }
            }
            val failure = ScheduleResult(
                scheduled = false,
                failure = IllegalStateException("texture output is released"),
            )
            for (waiter in waiters) {
                waiter.complete(failure)
            }
            clearCurrentFrame()
            releaseProducer()
        }

        private fun blitConfigured(frameAddress: Long): BlitResult {
            val started = System.nanoTime()
            val rawStatus = NativeBlitter.blit(surface(), frameAddress)
            val blitMicros = (System.nanoTime() - started) / 1_000L
            val reconfigured = rawStatus == BLIT_OK_RECONFIGURED
            return BlitResult(
                status = if (reconfigured) BLIT_OK else rawStatus,
                blitMicros = blitMicros,
                surfaceReconfigureCount = if (reconfigured) 1 else 0,
            )
        }

        private fun surface(): Surface {
            check(surfaceAvailable) { "SurfaceProducer surface is unavailable" }
            return producer.surface.also { surfaceInitialized = true }
        }

        private fun replaceCurrentFrame(frameAddress: Long, frameBytes: Long) {
            val previous = currentFrameAddress
            currentFrameAddress = frameAddress
            currentFrameBytes = frameBytes
            if (previous != 0L) {
                NativeBlitter.release(previous)
            }
        }

        private fun clearCurrentFrame() {
            val previous = currentFrameAddress
            currentFrameAddress = 0L
            currentFrameBytes = 0L
            if (previous != 0L) {
                NativeBlitter.release(previous)
            }
        }

        private data class ScheduleWaiter(
            val submittedNanos: Long,
            val complete: (ScheduleResult) -> Unit,
        )
    }

    private companion object {
        const val CHANNEL_NAME = "dev.zic/texture"
        const val BLIT_LANE_COUNT = 1
        const val BLIT_OK = 0
        const val BLIT_OK_RECONFIGURED = 6

        fun newBlitLane(index: Int): ExecutorService =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "zic-texture-blit-$index").apply {
                    isDaemon = true
                }
            }

        fun newScheduleCompletionExecutor(): ExecutorService =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "zic-texture-schedule-completion").apply {
                    isDaemon = true
                }
            }
    }
}

private fun MethodCall.intArgument(name: String): Int? = argument<Number>(name)?.toInt()
private fun MethodCall.longArgument(name: String): Long? = argument<Number>(name)?.toLong()
