package dev.zic.network

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class NetworkBridgePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingBrowserResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        failPendingBrowser("network bridge detached from Flutter engine")
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity(failPending = false)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity(failPending = true)
    }

    private fun attachActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    private fun detachActivity(failPending: Boolean) {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        if (failPending) {
            failPendingBrowser("host Activity detached while source browser was open")
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openBrowser" -> openBrowser(call, result)
            "openExternalBrowser" -> openExternalBrowser(call, result)
            "readBrowserSnapshot" -> readBrowserSnapshot(call, result)
            else -> result.notImplemented()
        }
    }

    private fun openBrowser(call: MethodCall, result: MethodChannel.Result) {
        val url = call.httpUrlOrError(result) ?: return
        val userAgent = call.argument<String>("userAgent")?.trim()?.takeIf(String::isNotEmpty)
        val cloudflareVerification = call.argument<Boolean>("cloudflareVerification") == true
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error(
                "network-browser-unavailable",
                "source browser requires an attached Activity",
                null,
            )
            return
        }
        if (pendingBrowserResult != null) {
            result.error(
                "network-browser-busy",
                "another source browser is already open",
                null,
            )
            return
        }
        pendingBrowserResult = result
        runCatching {
            activity.startActivityForResult(
                Intent(activity, NetworkBrowserActivity::class.java)
                    .putExtra(NetworkBrowserActivity.EXTRA_URL, url)
                    .apply {
                        if (userAgent != null) {
                            putExtra(NetworkBrowserActivity.EXTRA_USER_AGENT, userAgent)
                        }
                        if (cloudflareVerification) {
                            putExtra(
                                NetworkBrowserActivity.EXTRA_CLOUDFLARE_VERIFICATION,
                                true,
                            )
                        }
                    },
                BROWSER_REQUEST_CODE,
            )
        }.onFailure { error ->
            pendingBrowserResult = null
            result.error("network-browser-failed", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != BROWSER_REQUEST_CODE) return false
        val result = pendingBrowserResult
        pendingBrowserResult = null
        if (result == null) return true
        when (resultCode) {
            Activity.RESULT_OK -> result.success(null)
            Activity.RESULT_FIRST_USER -> result.error(
                "network-browser-failed",
                data?.getStringExtra(NetworkBrowserActivity.EXTRA_ERROR)
                    ?: "source browser failed",
                null,
            )
            else -> result.error(
                "network-browser-cancelled",
                "source browser was closed before verification completed",
                null,
            )
        }
        return true
    }

    private fun readBrowserSnapshot(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val url = call.httpUrlOrError(result) ?: return
        result.success(NetworkBrowserSnapshotStore.read(context, url))
    }

    private fun openExternalBrowser(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val url = call.httpUrlOrError(result) ?: return
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error(
                "external-browser-unavailable",
                "external browser requires an attached Activity",
                null,
            )
            return
        }
        runCatching {
            activity.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url)),
            )
        }.onSuccess {
            result.success(null)
        }.onFailure { error ->
            result.error("external-browser-failed", error.message, null)
        }
    }

    private fun failPendingBrowser(message: String) {
        val result = pendingBrowserResult ?: return
        pendingBrowserResult = null
        result.error("network-browser-unavailable", message, null)
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
        private const val BROWSER_REQUEST_CODE = 0x5A1C
    }
}
