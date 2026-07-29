package dev.zic.pluginhost

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class PluginHostBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var runtimeChannel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var inspector: ExecutorService? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        inspector = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-mihon-apk-inspector").apply { isDaemon = true }
        }
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        runtimeChannel = MethodChannel(binding.binaryMessenger, RUNTIME_CHANNEL_NAME)
        runtimeChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        runtimeChannel.setMethodCallHandler(null)
        inspector?.shutdownNow()
        inspector = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readMihonApkMetadata" -> readMihonApkMetadata(call, result)
            "activateMihonRuntime",
            "activateVeneraRuntime" -> result.error(
                "runtime-backend-unavailable",
                "The isolated plugin runtime service is not installed",
                null,
            )
            "invokeExternalRuntime",
            "cancelExternalRuntime",
            "closeExternalRuntime" -> result.error(
                "runtime-session-missing",
                "No isolated plugin runtime session is active",
                null,
            )
            else -> result.notImplemented()
        }
    }

    private fun readMihonApkMetadata(call: MethodCall, result: MethodChannel.Result) {
        val apkPath = call.argument<String>("apkPath")
        if (apkPath.isNullOrBlank()) {
            result.error("invalid-argument", "apkPath is required", null)
            return
        }
        val executor = inspector
        if (executor == null || executor.isShutdown) {
            result.error("bridge-closed", "plugin metadata bridge is closed", null)
            return
        }
        executor.execute {
            val response = runCatching { inspectMihonApk(apkPath) }
            mainHandler.post {
                response.fold(
                    onSuccess = result::success,
                    onFailure = { error ->
                        result.error(
                            "apk-metadata-failed",
                            error.message,
                            error.javaClass.name,
                        )
                    },
                )
            }
        }
    }

    private fun inspectMihonApk(apkPath: String): Map<String, Any> {
        val apk = File(apkPath)
        require(apk.isFile) { "APK file does not exist" }
        val info = packageInfo(apkPath)
            ?: throw IllegalArgumentException("PackageManager rejected APK")
        val applicationInfo = requireNotNull(info.applicationInfo) {
            "APK application metadata is missing"
        }.apply {
            sourceDir = apkPath
            publicSourceDir = apkPath
        }
        val metadata = applicationInfo.metaData
        val extensionLib = EXTENSION_LIB_KEYS
            .firstNotNullOfOrNull { key -> metadata?.getString(key)?.trim() }
            ?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("Mihon extension ABI metadata is missing")
        val rawEntryClasses = ENTRY_CLASS_KEYS
            .firstNotNullOfOrNull { key -> metadata?.getString(key)?.trim() }
            ?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("Mihon extension entry metadata is missing")
        val entryClasses = rawEntryClasses
            .split(';')
            .map(String::trim)
            .filter(String::isNotEmpty)
            .map { value ->
                val expanded = if (value.startsWith('.')) {
                    info.packageName + value
                } else {
                    value
                }
                require(CLASS_NAME.matches(expanded)) {
                    "Mihon extension entry class is invalid"
                }
                expanded
            }
            .distinct()
        require(entryClasses.isNotEmpty()) { "Mihon extension entry metadata is empty" }
        val signer = signingCertificates(info).singleOrNull()
            ?: throw IllegalArgumentException("APK must have exactly one current signer")
        return mapOf(
            "packageName" to info.packageName,
            "signerSha256" to sha256(signer.toByteArray()),
            "versionCode" to versionCode(info),
            "extensionLib" to extensionLib,
            "entryClasses" to entryClasses,
        )
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(apkPath: String): PackageInfo? {
        val flags = PackageManager.GET_META_DATA or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                PackageManager.GET_SIGNATURES
            }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageArchiveInfo(
                apkPath,
                PackageManager.PackageInfoFlags.of(flags.toLong()),
            )
        } else {
            context.packageManager.getPackageArchiveInfo(apkPath, flags)
        }
    }

    @Suppress("DEPRECATION")
    private fun signingCertificates(info: PackageInfo) =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = requireNotNull(info.signingInfo) {
                "APK signing information is missing"
            }
            signingInfo.apkContentsSigners.toList()
        } else {
            info.signatures?.toList().orEmpty()
        }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString(separator = "") { byte ->
                "%02x".format(byte.toInt() and 0xff)
            }

    companion object {
        private const val CHANNEL_NAME = "dev.zic/plugin_host_bridge"
        private const val RUNTIME_CHANNEL_NAME =
            "dev.zic/plugin_host_runtime_bridge"
        private val CLASS_NAME = Regex(
            "[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)+",
        )
        private val EXTENSION_LIB_KEYS = listOf(
            "tachiyomix.extensionLib",
            "tachiyomi.extensionLib",
            "tachiyomi.extension.lib",
        )
        private val ENTRY_CLASS_KEYS = listOf(
            "tachiyomix.extension.class",
            "tachiyomi.extension.class",
        )
    }
}
