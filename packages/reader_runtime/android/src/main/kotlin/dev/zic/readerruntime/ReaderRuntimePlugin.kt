package dev.zic.readerruntime

import android.app.Activity
import android.os.Build
import android.os.Debug
import android.view.Choreographer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import kotlin.math.roundToLong

class ReaderRuntimePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware {
    private lateinit var cadenceChannel: MethodChannel
    private lateinit var frameRatePolicyChannel: MethodChannel
    private val samples = ArrayDeque<Map<String, Long>>()
    private var monitoring = false
    private var anchorNanos = 0L
    private var lastFrameTimeNanos = 0L
    private var lastCallbackNanos = 0L
    private var lastThreadCpuNanos = 0L

    private var activity: Activity? = null
    private var verticalReaderFrameRatePolicyRequested = false
    private var policyActivity: Activity? = null
    private var previousFrameRatePowerSavingsBalanced: Boolean? = null

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!monitoring) return
            val callbackNanos = System.nanoTime()
            val threadCpuNanos = Debug.threadCpuTimeNanos()
            val priorFrame = lastFrameTimeNanos
            val priorCallback = lastCallbackNanos
            val priorCpu = lastThreadCpuNanos
            if (priorFrame != 0L && priorCallback != 0L && priorCpu != 0L) {
                val frameGapMicros = (frameTimeNanos - priorFrame) / 1_000L
                val callbackGapMicros = (callbackNanos - priorCallback) / 1_000L
                val callbackLagMicros =
                    maxOf(0L, (callbackNanos - frameTimeNanos) / 1_000L)
                val threadCpuGapMicros =
                    maxOf(0L, (threadCpuNanos - priorCpu) / 1_000L)
                if (frameGapMicros >= FRAME_GAP_OUTLIER_MICROS ||
                    callbackGapMicros >= FRAME_GAP_OUTLIER_MICROS ||
                    callbackLagMicros >= CALLBACK_LAG_OUTLIER_MICROS
                ) {
                    val sample = mutableMapOf(
                        "frameTimeNanos" to frameTimeNanos,
                        "callbackNanos" to callbackNanos,
                        "frameGapMicros" to frameGapMicros,
                        "callbackGapMicros" to callbackGapMicros,
                        "callbackLagMicros" to callbackLagMicros,
                        "threadCpuGapMicros" to threadCpuGapMicros,
                        "frameRatePolicyRequested" to
                            if (verticalReaderFrameRatePolicyRequested) 1L else 0L,
                    )
                    displayRefreshRateMilliHz()?.let {
                        sample["displayRefreshRateMilliHz"] = it
                    }
                    displayHasArrSupport()?.let {
                        sample["displayHasArrSupport"] = if (it) 1L else 0L
                    }
                    appendSample(sample)
                }
            }
            lastFrameTimeNanos = frameTimeNanos
            lastCallbackNanos = callbackNanos
            lastThreadCpuNanos = threadCpuNanos
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cadenceChannel = MethodChannel(binding.binaryMessenger, CADENCE_CHANNEL_NAME)
        cadenceChannel.setMethodCallHandler(this)
        frameRatePolicyChannel =
            MethodChannel(binding.binaryMessenger, FRAME_RATE_POLICY_CHANNEL_NAME)
        frameRatePolicyChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopMonitoring()
        restoreFrameRatePolicy()
        cadenceChannel.setMethodCallHandler(null)
        frameRatePolicyChannel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (verticalReaderFrameRatePolicyRequested) {
            applyFrameRatePolicy()
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        restoreFrameRatePolicy(keepRequested = true)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (verticalReaderFrameRatePolicyRequested) {
            applyFrameRatePolicy()
        }
    }

    override fun onDetachedFromActivity() {
        restoreFrameRatePolicy(keepRequested = true)
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startFrameCadenceProbe" -> {
                stopMonitoring()
                synchronized(samples) { samples.clear() }
                anchorNanos = System.nanoTime()
                lastFrameTimeNanos = 0L
                lastCallbackNanos = 0L
                lastThreadCpuNanos = 0L
                monitoring = true
                Choreographer.getInstance().postFrameCallback(frameCallback)
                result.success(
                    mapOf(
                        "nativeAnchorNanos" to anchorNanos,
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "displayRefreshRateMilliHz" to displayRefreshRateMilliHz(),
                    ),
                )
            }
            "drainFrameCadenceProbe" -> result.success(drainSamples())
            "stopFrameCadenceProbe" -> {
                stopMonitoring()
                result.success(drainSamples())
            }
            "setVerticalReaderFrameRatePolicy" -> {
                val active = call.argument<Boolean>("active") ?: false
                verticalReaderFrameRatePolicyRequested = active
                result.success(
                    if (active) {
                        applyFrameRatePolicy()
                    } else {
                        restoreFrameRatePolicy()
                    },
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun stopMonitoring() {
        if (!monitoring) return
        monitoring = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
    }

    private fun applyFrameRatePolicy(): Map<String, Any?> {
        val currentActivity = activity
        val refreshRateMilliHz = displayRefreshRateMilliHz()
        if (currentActivity == null) {
            return policyResult(
                applied = false,
                previousBalanced = null,
                currentBalanced = null,
                refreshRateMilliHz = refreshRateMilliHz,
                reason = "activity-unavailable",
            )
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            return policyResult(
                applied = false,
                previousBalanced = null,
                currentBalanced = null,
                refreshRateMilliHz = refreshRateMilliHz,
                reason = "api-below-35",
            )
        }

        if (policyActivity !== currentActivity) {
            restoreFrameRatePolicy(keepRequested = true)
            policyActivity = currentActivity
            previousFrameRatePowerSavingsBalanced =
                currentActivity.window.isFrameRatePowerSavingsBalanced
        }
        val previous = previousFrameRatePowerSavingsBalanced
        currentActivity.window.isFrameRatePowerSavingsBalanced = false
        return policyResult(
            applied = true,
            previousBalanced = previous,
            currentBalanced = currentActivity.window.isFrameRatePowerSavingsBalanced,
            refreshRateMilliHz = displayRefreshRateMilliHz(),
            reason = "reader-arr-disabled",
        )
    }

    private fun restoreFrameRatePolicy(keepRequested: Boolean = false): Map<String, Any?> {
        val targetActivity = policyActivity
        val previous = previousFrameRatePowerSavingsBalanced
        var restored = false
        var current: Boolean? = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
            targetActivity != null && previous != null
        ) {
            targetActivity.window.isFrameRatePowerSavingsBalanced = previous
            current = targetActivity.window.isFrameRatePowerSavingsBalanced
            restored = true
        }
        policyActivity = null
        previousFrameRatePowerSavingsBalanced = null
        if (!keepRequested) {
            verticalReaderFrameRatePolicyRequested = false
        }
        return policyResult(
            applied = restored,
            previousBalanced = previous,
            currentBalanced = current,
            refreshRateMilliHz = displayRefreshRateMilliHz(),
            reason = if (restored) "reader-arr-restored" else "nothing-to-restore",
        )
    }

    private fun policyResult(
        applied: Boolean,
        previousBalanced: Boolean?,
        currentBalanced: Boolean?,
        refreshRateMilliHz: Long?,
        reason: String,
    ): Map<String, Any?> = mapOf(
        "sdkInt" to Build.VERSION.SDK_INT,
        "requested" to verticalReaderFrameRatePolicyRequested,
        "applied" to applied,
        "previousBalanced" to previousBalanced,
        "currentBalanced" to currentBalanced,
        "displayRefreshRateMilliHz" to refreshRateMilliHz,
        "displayHasArrSupport" to displayHasArrSupport(),
        "reason" to reason,
    )

    private fun displayRefreshRateMilliHz(): Long? {
        val display = activity?.window?.decorView?.display ?: return null
        return (display.refreshRate * 1_000.0f).roundToLong()
    }

    private fun displayHasArrSupport(): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) return null
        val display = activity?.window?.decorView?.display ?: return null
        return display.hasArrSupport()
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
        private const val CADENCE_CHANNEL_NAME = "dev.zic/reader_runtime_frame_cadence"
        private const val FRAME_RATE_POLICY_CHANNEL_NAME =
            "dev.zic/reader_runtime_frame_rate_policy"
        private const val FRAME_GAP_OUTLIER_MICROS = 20_000L
        private const val CALLBACK_LAG_OUTLIER_MICROS = 8_000L
        private const val MAX_SAMPLES = 256
    }
}
