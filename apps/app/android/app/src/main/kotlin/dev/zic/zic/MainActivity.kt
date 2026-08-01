package dev.zic.zic

import android.net.Uri
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var pendingTraceResult: MethodChannel.Result? = null
    private var pendingTraceBytes: ByteArray? = null

    private val createTraceDocument = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/x-ndjson")
    ) { uri: Uri? ->
        val result = pendingTraceResult
        val bytes = pendingTraceBytes
        pendingTraceResult = null
        pendingTraceBytes = null
        if (result == null) return@registerForActivityResult
        if (uri == null) {
            result.success(null)
            return@registerForActivityResult
        }
        try {
            contentResolver.openOutputStream(uri, "wt").use { output ->
                requireNotNull(output) { "unable to open selected document" }
                output.write(requireNotNull(bytes) { "trace export payload missing" })
                output.flush()
            }
            result.success(uri.toString())
        } catch (error: Throwable) {
            result.error(
                "trace-export-write-failed",
                error.message ?: error.javaClass.simpleName,
                null,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.zic.zic/debug_trace_export",
        ).setMethodCallHandler(::handleTraceExport)
    }

    private fun handleTraceExport(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveJsonl") {
            result.notImplemented()
            return
        }
        if (pendingTraceResult != null) {
            result.error("trace-export-busy", "another trace export is active", null)
            return
        }
        val suggestedName = call.argument<String>("suggestedName")
        val bytes = call.argument<ByteArray>("bytes")
        if (suggestedName.isNullOrBlank() || bytes == null) {
            result.error("trace-export-arguments", "name and bytes are required", null)
            return
        }
        pendingTraceResult = result
        pendingTraceBytes = bytes
        try {
            createTraceDocument.launch(suggestedName)
        } catch (error: Throwable) {
            pendingTraceResult = null
            pendingTraceBytes = null
            result.error(
                "trace-export-launch-failed",
                error.message ?: error.javaClass.simpleName,
                null,
            )
        }
    }

    override fun onDestroy() {
        pendingTraceResult?.error(
            "trace-export-cancelled",
            "activity destroyed during trace export",
            null,
        )
        pendingTraceResult = null
        pendingTraceBytes = null
        super.onDestroy()
    }
}
