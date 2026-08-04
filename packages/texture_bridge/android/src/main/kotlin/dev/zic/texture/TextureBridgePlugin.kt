package dev.zic.texture

import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.view.TextureRegistry
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
    external fun blit(surface: Surface, frameAddress: Long): Int
}

class TextureBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val outputs = mutableMapOf<Long, Output>()
    private val lifecycleLock = Any()
    private val detached = AtomicBoolean(true)
    private var queuedBytes = AtomicLong(0)

    private var blitLanes: List<ExecutorService> = emptyList()
    private val nextBlitLane = AtomicInteger(0)
    private lateinit var textures: TextureRegistry
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(lifecycleLock) { detached.set(false) }
        queuedBytes = AtomicLong(0)
        nextBlitLane.set(0)
        blitLanes = List(BLIT_LANE_COUNT, ::newBlitLane)
        blitLanes.forEach { lane -> lane.execute {} }
        textures = binding.textureRegistry
        val taskQueue: BinaryMessenger.TaskQueue =
            binding.binaryMessenger.makeBackgroundTaskQueue()
        channel = MethodChannel(
            binding.binaryMessenger,
            CHANNEL_NAME,
            StandardMethodCodec.INSTANCE,
            taskQueue,
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(lifecycleLock) { detached.set(true) }
        channel.setMethodCallHandler(null)
        val owned = synchronized(outputs) {
            outputs.values.toList().also { outputs.clear() }
        }
        val lanes = blitLanes
        blitLanes = emptyList()
        for (output in owned) {
            try {
                output.lane.execute(output::release)
            } catch (_: RejectedExecutionException) {
                output.release()
            }
        }
        lanes.forEach(ExecutorService::shutdown)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> create(call, result)
            "resize" -> resize(call, result)
            "present" -> present(call, result)
            "redraw" -> redraw(call, result)
            "release" -> release(call, result)
            else -> result.notImplemented()
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
                        complete = complete,
                    )
                },
                scheduleRedraw = { target -> scheduleRedraw(target) },
                resizeProducer = { nextWidth, nextHeight ->
                    mainHandler.post {
                        if (!output.isReleased && !detached.get()) {
                            producer.setSize(nextWidth, nextHeight)
                        }
                    }
                },
                releaseProducer = {
                    mainHandler.post {
                        producer.setCallback(null)
                        producer.release()
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
                            result.error(
                                "blit_failed",
                                failure.message ?: failure.toString(),
                                null,
                            )
                            return
                        }
                        check(presentation != null)
                        if (presentation.failure != null) {
                            result.error(
                                "schedule_failed",
                                presentation.failure.message
                                    ?: presentation.failure.toString(),
                                null,
                            )
                            return
                        }
                        if (presentation.status != 0) {
                            result.error(
                                "blit_failed",
                                "native blit failed with status ${presentation.status}",
                                null,
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
                            // Completion runs in the same platform-thread runnable
                            // immediately after scheduleFrame().
                            "resultDispatchMicros" to 0L,
                        )
                        result.success(response)
                    } catch (error: Throwable) {
                        result.error(
                            "blit_failed",
                            error.message ?: error.toString(),
                            null,
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
        complete: (ScheduleResult) -> Unit,
    ): Boolean {
        fun schedule(queueMicros: Long) {
            val result = try {
                synchronized(lifecycleLock) {
                    if (detached.get() || !canSchedule()) {
                        ScheduleResult(scheduled = false, queueMicros = queueMicros)
                    } else {
                        val callStartedNanos = System.nanoTime()
                        producer.scheduleFrame()
                        ScheduleResult(
                            scheduled = true,
                            queueMicros = queueMicros,
                            callMicros =
                                (System.nanoTime() - callStartedNanos) / 1_000L,
                        )
                    }
                }
            } catch (error: Throwable) {
                ScheduleResult(
                    scheduled = false,
                    queueMicros = queueMicros,
                    failure = error,
                )
            }
            complete(result)
        }

        if (Looper.myLooper() == mainHandler.looper) {
            schedule(0L)
            return true
        }

        val submittedNanos = System.nanoTime()
        return mainHandler.postAtFrontOfQueue {
            schedule((System.nanoTime() - submittedNanos) / 1_000L)
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
        @Volatile
        private var surfaceAvailable = true

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
                val accepted = scheduleFrame { schedule ->
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
                if (!accepted) {
                    complete(
                        PresentResult(
                            status = -1,
                            retainMicros = retainMicros,
                                                        blitMicros = blit.blitMicros,
                            surfaceReconfigureCount = blit.surfaceReconfigureCount,
                            scheduleMicros = 0L,
                            scheduleQueueMicros = 0L,
                            scheduleCallMicros = 0L,
                            replaceMicros = replaceMicros,
                        ),
                    )
                }
            } finally {
                if (currentFrameAddress != retained) {
                    NativeBlitter.release(retained)
                }
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
                scheduleFrame { _ -> }
            }
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
            return producer.surface
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
    }

    private companion object {
        const val CHANNEL_NAME = "dev.zic/texture"
        const val BLIT_LANE_COUNT = 2
        const val BLIT_OK = 0
        const val BLIT_OK_RECONFIGURED = 6

        fun newBlitLane(index: Int): ExecutorService =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "zic-texture-blit-$index").apply {
                    isDaemon = true
                }
            }
    }
}

private fun MethodCall.intArgument(name: String): Int? = argument<Number>(name)?.toInt()
private fun MethodCall.longArgument(name: String): Long? = argument<Number>(name)?.toLong()
