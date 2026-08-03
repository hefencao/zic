package dev.zic.texture

import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
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

    private var blitLane: ExecutorService? = null
    private lateinit var textures: TextureRegistry
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(lifecycleLock) { detached.set(false) }
        queuedBytes = AtomicLong(0)
        blitLane = newBlitLane()
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(lifecycleLock) { detached.set(true) }
        channel.setMethodCallHandler(null)
        val owned = synchronized(outputs) {
            outputs.values.toList().also { outputs.clear() }
        }
        val lane = blitLane
        blitLane = null
        if (lane == null) {
            owned.forEach(Output::release)
        } else {
            try {
                lane.execute { owned.forEach(Output::release) }
            } catch (_: RejectedExecutionException) {
                owned.forEach(Output::release)
            } finally {
                lane.shutdown()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> create(call, result)
            "resize" -> resize(call, result)
            "present" -> present(call, result)
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
        val lane = blitLane
        if (lane == null || detached.get()) {
            result.error("detached", "texture bridge is detached", null)
            return
        }
        val producer = textures.createSurfaceProducer()
        producer.setSize(width, height)
        lateinit var output: Output
        output = Output(
            producer = producer,
            width = width,
            height = height,
            canPresent = { !detached.get() },
            scheduleFrame = {
                scheduleProducerFrame(producer) { !output.isReleased }
            },
            scheduleRedraw = { target -> scheduleRedraw(lane, target) },
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
        val lane = lane(result) ?: return
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
        val lane = lane(result) ?: return
        val submittedNanos = System.nanoTime()
        val queue = queuedBytes
        queue.addAndGet(frameBytes)
        try {
            lane.execute {
                try {
                    val startedNanos = System.nanoTime()
                    val presentation = output.present(frameAddress, frameBytes)
                    val finishedNanos = System.nanoTime()
                    if (presentation.status != 0) {
                        error(
                            result,
                            "blit_failed",
                            "native blit failed with status ${presentation.status}",
                        )
                        return@execute
                    }
                    val elapsedMicros = (finishedNanos - submittedNanos) / 1_000L
                    val otherQueuedBytes = maxOf(0L, queue.get() - frameBytes)
                    val response = mapOf(
                        "queueMicros" to
                            (startedNanos - submittedNanos) / 1_000L,
                        "uploadMicros" to
                            (finishedNanos - startedNanos) / 1_000L,
                        "retainMicros" to presentation.retainMicros,
                        "blitMicros" to presentation.blitMicros,
                        "scheduleMicros" to presentation.scheduleMicros,
                        "replaceMicros" to presentation.replaceMicros,
                        "deadlineMissMicros" to if (deadlineAfterMicros == null) {
                            0L
                        } else {
                            maxOf(0L, elapsedMicros - deadlineAfterMicros)
                        },
                        "textureBytes" to output.textureBytes,
                        "inFlightBytes" to
                            output.retainedFrameBytes + otherQueuedBytes,
                    )
                    mainHandler.post {
                        result.success(
                            response + mapOf(
                                "resultDispatchMicros" to
                                    (System.nanoTime() - finishedNanos) / 1_000L,
                            ),
                        )
                    }
                } catch (error: Throwable) {
                    error(result, "blit_failed", error.message ?: error.toString())
                } finally {
                    queue.addAndGet(-frameBytes)
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
        val lane = lane(result) ?: run {
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

    private fun lane(result: MethodChannel.Result): ExecutorService? {
        val lane = blitLane
        if (lane == null || detached.get()) {
            result.error("detached", "texture bridge is detached", null)
            return null
        }
        return lane
    }

    private fun scheduleProducerFrame(
        producer: TextureRegistry.SurfaceProducer,
        canSchedule: () -> Boolean,
    ): Boolean = synchronized(lifecycleLock) {
        if (detached.get() || !canSchedule()) {
            false
        } else {
            mainHandler.post {
                synchronized(lifecycleLock) {
                    if (!detached.get() && canSchedule()) {
                        producer.scheduleFrame()
                    }
                }
            }
            true
        }
    }

    private fun scheduleRedraw(lane: ExecutorService, output: Output) {
        try {
            lane.execute { output.redraw() }
        } catch (_: RejectedExecutionException) {
            // Detach or shutdown owns final cleanup.
        }
    }

    private fun success(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun error(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private data class PresentResult(
        val status: Int,
        val retainMicros: Long,
        val blitMicros: Long,
        val scheduleMicros: Long,
        val replaceMicros: Long,
    )

    @Suppress("DEPRECATION")
    private class Output(
        private val producer: TextureRegistry.SurfaceProducer,
        private var width: Int,
        private var height: Int,
        private val canPresent: () -> Boolean,
        private val scheduleFrame: () -> Boolean,
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

        fun present(frameAddress: Long, frameBytes: Long): PresentResult {
            check(!released) { "texture output is released" }
            check(canPresent()) { "texture bridge is detached" }
            val retainStartedNanos = System.nanoTime()
            val retained = NativeBlitter.retain(frameAddress)
            val retainFinishedNanos = System.nanoTime()
            check(retained != 0L) { "native frame retain failed" }
            try {
                val blitStartedNanos = System.nanoTime()
                val status = NativeBlitter.blit(surface(), retained)
                val blitFinishedNanos = System.nanoTime()
                if (status != 0) {
                    return PresentResult(
                        status = status,
                        retainMicros = (retainFinishedNanos - retainStartedNanos) / 1_000L,
                        blitMicros = (blitFinishedNanos - blitStartedNanos) / 1_000L,
                        scheduleMicros = 0L,
                        replaceMicros = 0L,
                    )
                }
                val scheduleStartedNanos = System.nanoTime()
                check(scheduleFrame()) { "texture bridge detached during blit" }
                val scheduleFinishedNanos = System.nanoTime()
                val replaceStartedNanos = System.nanoTime()
                replaceCurrentFrame(retained, frameBytes)
                val replaceFinishedNanos = System.nanoTime()
                return PresentResult(
                    status = 0,
                    retainMicros = (retainFinishedNanos - retainStartedNanos) / 1_000L,
                    blitMicros = (blitFinishedNanos - blitStartedNanos) / 1_000L,
                    scheduleMicros = (scheduleFinishedNanos - scheduleStartedNanos) / 1_000L,
                    replaceMicros = (replaceFinishedNanos - replaceStartedNanos) / 1_000L,
                )
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
            if (NativeBlitter.blit(surface(), currentFrameAddress) == 0) {
                scheduleFrame()
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

        fun newBlitLane(): ExecutorService =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "zic-texture-blit").apply { isDaemon = true }
            }
    }
}

private fun MethodCall.intArgument(name: String): Int? = argument<Number>(name)?.toInt()
private fun MethodCall.longArgument(name: String): Long? = argument<Number>(name)?.toLong()
