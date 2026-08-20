package dev.zic.readerruntime

import android.app.Activity
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.HandlerThread
import android.view.Choreographer
import android.view.FrameMetrics
import android.view.Window
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
    private var summaryFirstFrameTimeNanos = 0L
    private var summaryLastFrameTimeNanos = 0L
    private var summaryIntervalCount = 0L
    private var summaryFrameGapSumMicros = 0L
    private var summaryMinFrameGapMicros = Long.MAX_VALUE
    private var summaryMaxFrameGapMicros = 0L
    private val summaryFrameGapBins = LongArray(FRAME_GAP_BIN_COUNT)

    private val windowFrameSamples = ArrayDeque<Map<String, Long>>()
    private var windowMetricsActivity: Activity? = null
    private var windowMetricsThread: HandlerThread? = null
    private var windowMetricsListener: Window.OnFrameMetricsAvailableListener? = null
    @Volatile
    private var windowMetricsDisplayRefreshRateMilliHz: Long? = null
    private var windowSummaryFrameCount = 0L
    private var windowSummaryDroppedReports = 0L
    private var windowSummaryTotalDurationSumMicros = 0L
    private var windowSummaryUnknownDelaySumMicros = 0L
    private var windowSummaryMaxTotalDurationMicros = 0L
    private var windowSummaryMaxUnknownDelayMicros = 0L
    private val windowSummaryTotalBins = LongArray(WINDOW_DURATION_BIN_COUNT)
    private val windowSummaryUnknownBins = LongArray(WINDOW_UNKNOWN_BIN_COUNT)

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
                recordFrameGap(priorFrame, frameTimeNanos, frameGapMicros)
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
        if (monitoring) {
            attachWindowFrameMetrics(binding.activity)
        }
        if (verticalReaderFrameRatePolicyRequested) {
            applyFrameRatePolicy()
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachWindowFrameMetrics()
        restoreFrameRatePolicy(keepRequested = true)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (monitoring) {
            attachWindowFrameMetrics(binding.activity)
        }
        if (verticalReaderFrameRatePolicyRequested) {
            applyFrameRatePolicy()
        }
    }

    override fun onDetachedFromActivity() {
        detachWindowFrameMetrics()
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
                resetFrameCadenceSummary()
                resetWindowFrameMetrics()
                monitoring = true
                activity?.let { attachWindowFrameMetrics(it) }
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
            "drainFrameCadenceSummary" -> result.success(drainFrameCadenceSummary())
            "drainWindowFrameMetricsProbe" ->
                result.success(drainWindowFrameMetricSamples())
            "drainWindowFrameMetricsSummary" ->
                result.success(drainWindowFrameMetricsSummary())
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
        val wasMonitoring = monitoring
        monitoring = false
        if (wasMonitoring) {
            Choreographer.getInstance().removeFrameCallback(frameCallback)
        }
        detachWindowFrameMetrics()
    }

    private fun attachWindowFrameMetrics(target: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        if (windowMetricsActivity === target && windowMetricsListener != null) {
            return
        }
        detachWindowFrameMetrics()
        val refreshRateMilliHz = displayRefreshRateMilliHz()
        val thread = HandlerThread("zic-reader-window-metrics")
        thread.start()
        val handler = Handler(thread.looper)
        val listener = Window.OnFrameMetricsAvailableListener {
            _, metrics, droppedReports ->
            recordWindowFrameMetrics(metrics, droppedReports)
        }
        try {
            target.window.addOnFrameMetricsAvailableListener(listener, handler)
        } catch (_: Throwable) {
            thread.quitSafely()
            return
        }
        windowMetricsActivity = target
        windowMetricsThread = thread
        windowMetricsListener = listener
        windowMetricsDisplayRefreshRateMilliHz = refreshRateMilliHz
    }

    private fun detachWindowFrameMetrics() {
        val target = windowMetricsActivity
        val listener = windowMetricsListener
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            target != null &&
            listener != null
        ) {
            try {
                target.window.removeOnFrameMetricsAvailableListener(listener)
            } catch (_: Throwable) {
                // Diagnostics must not interfere with Reader teardown.
            }
        }
        windowMetricsActivity = null
        windowMetricsListener = null
        windowMetricsDisplayRefreshRateMilliHz = null
        windowMetricsThread?.quitSafely()
        windowMetricsThread = null
    }

    private fun recordWindowFrameMetrics(
        metrics: FrameMetrics,
        droppedReports: Int,
    ) {
        if (!monitoring || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val callbackNanos = System.nanoTime()
        val totalMicros = frameMetricMicros(metrics, FrameMetrics.TOTAL_DURATION)
        val unknownMicros =
            frameMetricMicros(metrics, FrameMetrics.UNKNOWN_DELAY_DURATION)
        val inputMicros =
            frameMetricMicros(metrics, FrameMetrics.INPUT_HANDLING_DURATION)
        val animationMicros =
            frameMetricMicros(metrics, FrameMetrics.ANIMATION_DURATION)
        val layoutMeasureMicros =
            frameMetricMicros(metrics, FrameMetrics.LAYOUT_MEASURE_DURATION)
        val drawMicros = frameMetricMicros(metrics, FrameMetrics.DRAW_DURATION)
        val syncMicros = frameMetricMicros(metrics, FrameMetrics.SYNC_DURATION)
        val commandIssueMicros =
            frameMetricMicros(metrics, FrameMetrics.COMMAND_ISSUE_DURATION)
        val swapBuffersMicros =
            frameMetricMicros(metrics, FrameMetrics.SWAP_BUFFERS_DURATION)
        val intendedVsyncNanos = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            metrics.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP)
        } else {
            -1L
        }
        val vsyncNanos = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            metrics.getMetric(FrameMetrics.VSYNC_TIMESTAMP)
        } else {
            -1L
        }
        val refreshRateMilliHz = windowMetricsDisplayRefreshRateMilliHz
        synchronized(windowFrameSamples) {
            windowSummaryFrameCount += 1L
            windowSummaryDroppedReports += maxOf(0, droppedReports).toLong()
            windowSummaryTotalDurationSumMicros += totalMicros
            windowSummaryUnknownDelaySumMicros += unknownMicros
            windowSummaryMaxTotalDurationMicros =
                maxOf(windowSummaryMaxTotalDurationMicros, totalMicros)
            windowSummaryMaxUnknownDelayMicros =
                maxOf(windowSummaryMaxUnknownDelayMicros, unknownMicros)
            windowSummaryTotalBins[windowDurationBinIndex(totalMicros)] += 1L
            windowSummaryUnknownBins[windowUnknownBinIndex(unknownMicros)] += 1L
            val highRefresh =
                refreshRateMilliHz != null && refreshRateMilliHz >= 90_000L
            val totalThresholdMicros =
                if (highRefresh) 12_500L else 20_000L
            if (droppedReports <= 0 &&
                totalMicros < totalThresholdMicros &&
                unknownMicros < WINDOW_UNKNOWN_OUTLIER_MICROS
            ) {
                return
            }
            val sample = mutableMapOf(
                "callbackNanos" to callbackNanos,
                "totalDurationMicros" to totalMicros,
                "unknownDelayMicros" to unknownMicros,
                "inputHandlingMicros" to inputMicros,
                "animationMicros" to animationMicros,
                "layoutMeasureMicros" to layoutMeasureMicros,
                "drawMicros" to drawMicros,
                "syncMicros" to syncMicros,
                "commandIssueMicros" to commandIssueMicros,
                "swapBuffersMicros" to swapBuffersMicros,
                "droppedReports" to maxOf(0, droppedReports).toLong(),
            )
            if (intendedVsyncNanos > 0L) {
                sample["intendedVsyncNanos"] = intendedVsyncNanos
            }
            if (vsyncNanos > 0L) {
                sample["vsyncNanos"] = vsyncNanos
            }
            refreshRateMilliHz?.let {
                sample["displayRefreshRateMilliHz"] = it
            }
            appendWindowFrameMetricSample(sample)
        }
    }

    private fun resetWindowFrameMetrics() {
        synchronized(windowFrameSamples) {
            windowFrameSamples.clear()
            windowSummaryFrameCount = 0L
            windowSummaryDroppedReports = 0L
            windowSummaryTotalDurationSumMicros = 0L
            windowSummaryUnknownDelaySumMicros = 0L
            windowSummaryMaxTotalDurationMicros = 0L
            windowSummaryMaxUnknownDelayMicros = 0L
            windowSummaryTotalBins.fill(0L)
            windowSummaryUnknownBins.fill(0L)
        }
    }

    private fun drainWindowFrameMetricSamples(): List<Map<String, Long>> =
        synchronized(windowFrameSamples) {
            val drained = windowFrameSamples.toList()
            windowFrameSamples.clear()
            drained
        }

    private fun drainWindowFrameMetricsSummary(): Map<String, Long>? =
        synchronized(windowFrameSamples) {
            if (windowSummaryFrameCount == 0L) return@synchronized null
            val summary = mutableMapOf(
                "frameCount" to windowSummaryFrameCount,
                "droppedReports" to windowSummaryDroppedReports,
                "totalDurationSumMicros" to windowSummaryTotalDurationSumMicros,
                "unknownDelaySumMicros" to windowSummaryUnknownDelaySumMicros,
                "maxTotalDurationMicros" to windowSummaryMaxTotalDurationMicros,
                "maxUnknownDelayMicros" to windowSummaryMaxUnknownDelayMicros,
                "totalLt8msCount" to windowSummaryTotalBins[0],
                "total8To12msCount" to windowSummaryTotalBins[1],
                "total12To20msCount" to windowSummaryTotalBins[2],
                "total20To35msCount" to windowSummaryTotalBins[3],
                "totalGe35msCount" to windowSummaryTotalBins[4],
                "unknownLt2msCount" to windowSummaryUnknownBins[0],
                "unknown2To8msCount" to windowSummaryUnknownBins[1],
                "unknownGe8msCount" to windowSummaryUnknownBins[2],
            )
            windowMetricsDisplayRefreshRateMilliHz?.let {
                summary["displayRefreshRateMilliHz"] = it
            }
            windowSummaryFrameCount = 0L
            windowSummaryDroppedReports = 0L
            windowSummaryTotalDurationSumMicros = 0L
            windowSummaryUnknownDelaySumMicros = 0L
            windowSummaryMaxTotalDurationMicros = 0L
            windowSummaryMaxUnknownDelayMicros = 0L
            windowSummaryTotalBins.fill(0L)
            windowSummaryUnknownBins.fill(0L)
            summary
        }

    private fun appendWindowFrameMetricSample(sample: Map<String, Long>) {
        while (windowFrameSamples.size >= MAX_WINDOW_FRAME_SAMPLES) {
            windowFrameSamples.removeFirst()
        }
        windowFrameSamples.addLast(sample)
    }

    private fun frameMetricMicros(metrics: FrameMetrics, metric: Int): Long =
        maxOf(0L, metrics.getMetric(metric)) / 1_000L

    private fun windowDurationBinIndex(durationMicros: Long): Int = when {
        durationMicros < 8_000L -> 0
        durationMicros < 12_000L -> 1
        durationMicros < 20_000L -> 2
        durationMicros < 35_000L -> 3
        else -> 4
    }

    private fun windowUnknownBinIndex(durationMicros: Long): Int = when {
        durationMicros < 2_000L -> 0
        durationMicros < 8_000L -> 1
        else -> 2
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

    private fun recordFrameGap(
        priorFrameTimeNanos: Long,
        frameTimeNanos: Long,
        frameGapMicros: Long,
    ) {
        if (summaryFirstFrameTimeNanos == 0L) {
            summaryFirstFrameTimeNanos = priorFrameTimeNanos
        }
        summaryLastFrameTimeNanos = frameTimeNanos
        summaryIntervalCount += 1L
        summaryFrameGapSumMicros += frameGapMicros
        summaryMinFrameGapMicros = minOf(summaryMinFrameGapMicros, frameGapMicros)
        summaryMaxFrameGapMicros = maxOf(summaryMaxFrameGapMicros, frameGapMicros)
        summaryFrameGapBins[frameGapBinIndex(frameGapMicros)] += 1L
    }

    private fun frameGapBinIndex(frameGapMicros: Long): Int = when {
        frameGapMicros < 10_000L -> 0
        frameGapMicros < 14_000L -> 1
        frameGapMicros < 18_000L -> 2
        frameGapMicros < 20_000L -> 3
        frameGapMicros < 25_000L -> 4
        frameGapMicros < 35_000L -> 5
        else -> 6
    }

    private fun resetFrameCadenceSummary() {
        summaryFirstFrameTimeNanos = 0L
        summaryLastFrameTimeNanos = 0L
        summaryIntervalCount = 0L
        summaryFrameGapSumMicros = 0L
        summaryMinFrameGapMicros = Long.MAX_VALUE
        summaryMaxFrameGapMicros = 0L
        summaryFrameGapBins.fill(0L)
    }

    private fun drainFrameCadenceSummary(): Map<String, Long>? {
        if (summaryIntervalCount == 0L || summaryLastFrameTimeNanos == 0L) return null
        val summary = mutableMapOf(
            "firstFrameTimeNanos" to summaryFirstFrameTimeNanos,
            "lastFrameTimeNanos" to summaryLastFrameTimeNanos,
            "frameIntervalCount" to summaryIntervalCount,
            "frameGapSumMicros" to summaryFrameGapSumMicros,
            "minFrameGapMicros" to summaryMinFrameGapMicros,
            "maxFrameGapMicros" to summaryMaxFrameGapMicros,
            "gapLt10msCount" to summaryFrameGapBins[0],
            "gap10To14msCount" to summaryFrameGapBins[1],
            "gap14To18msCount" to summaryFrameGapBins[2],
            "gap18To20msCount" to summaryFrameGapBins[3],
            "gap20To25msCount" to summaryFrameGapBins[4],
            "gap25To35msCount" to summaryFrameGapBins[5],
            "gapGe35msCount" to summaryFrameGapBins[6],
            "frameRatePolicyRequested" to
                if (verticalReaderFrameRatePolicyRequested) 1L else 0L,
        )
        displayRefreshRateMilliHz()?.let {
            summary["displayRefreshRateMilliHz"] = it
        }
        displayHasArrSupport()?.let {
            summary["displayHasArrSupport"] = if (it) 1L else 0L
        }
        resetFrameCadenceSummary()
        return summary
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
        private const val FRAME_GAP_BIN_COUNT = 7
        private const val MAX_WINDOW_FRAME_SAMPLES = 64
        private const val WINDOW_DURATION_BIN_COUNT = 5
        private const val WINDOW_UNKNOWN_BIN_COUNT = 3
        private const val WINDOW_UNKNOWN_OUTLIER_MICROS = 8_000L
    }
}
