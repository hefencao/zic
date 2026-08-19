package dev.zic.readerruntime

import android.os.Choreographer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

class ReaderRuntimePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val samples = ArrayDeque<Map<String, Long>>()
    private var monitoring = false
    private var anchorNanos = 0L
    private var lastFrameTimeNanos = 0L
    private var lastCallbackNanos = 0L

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!monitoring) return
            val callbackNanos = System.nanoTime()
            val priorFrame = lastFrameTimeNanos
            val priorCallback = lastCallbackNanos
            if (priorFrame != 0L && priorCallback != 0L) {
                val frameGapMicros = (frameTimeNanos - priorFrame) / 1_000L
                val callbackGapMicros = (callbackNanos - priorCallback) / 1_000L
                val callbackLagMicros =
                    maxOf(0L, (callbackNanos - frameTimeNanos) / 1_000L)
                if (frameGapMicros >= FRAME_GAP_OUTLIER_MICROS ||
                    callbackGapMicros >= FRAME_GAP_OUTLIER_MICROS ||
                    callbackLagMicros >= CALLBACK_LAG_OUTLIER_MICROS
                ) {
                    appendSample(
                        mapOf(
                            "frameTimeNanos" to frameTimeNanos,
                            "callbackNanos" to callbackNanos,
                            "frameGapMicros" to frameGapMicros,
                            "callbackGapMicros" to callbackGapMicros,
                            "callbackLagMicros" to callbackLagMicros,
                        ),
                    )
                }
            }
            lastFrameTimeNanos = frameTimeNanos
            lastCallbackNanos = callbackNanos
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopMonitoring()
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startFrameCadenceProbe" -> {
                stopMonitoring()
                synchronized(samples) { samples.clear() }
                anchorNanos = System.nanoTime()
                lastFrameTimeNanos = 0L
                lastCallbackNanos = 0L
                monitoring = true
                Choreographer.getInstance().postFrameCallback(frameCallback)
                result.success(mapOf("nativeAnchorNanos" to anchorNanos))
            }
            "drainFrameCadenceProbe" -> result.success(drainSamples())
            "stopFrameCadenceProbe" -> {
                stopMonitoring()
                result.success(drainSamples())
            }
            else -> result.notImplemented()
        }
    }

    private fun stopMonitoring() {
        if (!monitoring) return
        monitoring = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
    }

    private fun appendSample(sample: Map<String, Long>) {
        synchronized(samples) {
            while (samples.size >= MAX_SAMPLES) {
                samples.removeFirst()
            }
            samples.addLast(sample)
        }
    }

    private fun drainSamples(): List<Map<String, Long>> = synchronized(samples) {
        val drained = samples.toList()
        samples.clear()
        drained
    }

    companion object {
        private const val CHANNEL_NAME = "dev.zic/reader_runtime_frame_cadence"
        private const val FRAME_GAP_OUTLIER_MICROS = 20_000L
        private const val CALLBACK_LAG_OUTLIER_MICROS = 8_000L
        private const val MAX_SAMPLES = 256
    }
}
