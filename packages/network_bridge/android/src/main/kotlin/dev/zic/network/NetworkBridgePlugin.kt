package dev.zic.network

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NetworkBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openBrowser" -> openBrowser(call, result)
            "readBrowserSnapshot" -> readBrowserSnapshot(call, result)
            else -> result.notImplemented()
        }
    }

    private fun openBrowser(call: MethodCall, result: MethodChannel.Result) {
        val url = call.httpUrlOrError(result) ?: return
        runCatching {
            context.startActivity(
                Intent(context, NetworkBrowserActivity::class.java)
                    .putExtra(NetworkBrowserActivity.EXTRA_URL, url)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }.onSuccess {
            result.success(null)
        }.onFailure { error ->
            result.error("network-browser-failed", error.message, null)
        }
    }

    private fun readBrowserSnapshot(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val url = call.httpUrlOrError(result) ?: return
        result.success(NetworkBrowserSnapshotStore.read(context, url))
    }

    private fun MethodCall.httpUrlOrError(
        result: MethodChannel.Result,
    ): String? {
        val url = argument<String>("url")
        if (url.isNullOrBlank() ||
            (!url.startsWith("https://") && !url.startsWith("http://"))
        ) {
            result.error("invalid-argument", "HTTP(S) browser URL is required", null)
            return null
        }
        return url
    }

    companion object {
        private const val CHANNEL_NAME = "dev.zic/network_bridge"
    }
}
