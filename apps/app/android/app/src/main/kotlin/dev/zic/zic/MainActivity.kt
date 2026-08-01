package dev.zic.zic

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TRACE_EXPORT_REQUEST = 0x5A49
        private const val TRACE_EXPORT_CHANNEL = "dev.zic.zic/debug_trace_export"
    }

    private var pendingTraceResult: MethodChannel.Result? = null
    private var pendingTraceBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TRACE_EXPORT_CHANNEL,
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
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/x-ndjson"
            putExtra(Intent.EXTRA_TITLE, suggestedName)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, TRACE_EXPORT_REQUEST)
        } catch (error: Throwable) {
            clearPendingTrace()
            result.error(
                "trace-export-launch-failed",
                error.message ?: error.javaClass.simpleName,
                null,
            )
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != TRACE_EXPORT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingTraceResult
        val bytes = pendingTraceBytes
        clearPendingTrace()
        if (result == null) return
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
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

    private fun clearPendingTrace() {
        pendingTraceResult = null
        pendingTraceBytes = null
    }

    override fun onDestroy() {
        pendingTraceResult?.error(
            "trace-export-cancelled",
            "activity destroyed during trace export",
            null,
        )
        clearPendingTrace()
        super.onDestroy()
    }
}
