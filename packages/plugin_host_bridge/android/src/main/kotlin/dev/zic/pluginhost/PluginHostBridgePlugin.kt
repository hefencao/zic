package dev.zic.pluginhost

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
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
    private var runtimeServiceClient: PluginRuntimeServiceClient? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        inspector = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-mihon-apk-inspector").apply { isDaemon = true }
        }
        runtimeServiceClient = PluginRuntimeServiceClient(context)
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
        runtimeServiceClient?.shutdown()
        runtimeServiceClient = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readMihonApkMetadata" -> readMihonApkMetadata(call, result)
            "listInstalledMihonExtensions" -> listInstalledMihonExtensions(result)
            "copyInstalledMihonExtension" -> copyInstalledMihonExtension(call, result)
            "activateMihonRuntime",
            "activateVeneraRuntime",
            "invokeExternalRuntime",
            "cancelExternalRuntime",
            "closeExternalRuntime",
            "closeExternalRuntimeProcess" -> {
                val client = runtimeServiceClient
                if (client == null) {
                    result.error(
                        "bridge-closed",
                        "plugin runtime bridge is closed",
                        null,
                    )
                } else {
                    client.invoke(call, result)
                }
            }
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

    private fun listInstalledMihonExtensions(result: MethodChannel.Result) {
        runInspection(result) {
            installedPackages()
                .asSequence()
                .filter(::isMihonExtension)
                .mapNotNull { info ->
                    runCatching {
                        val apkPath = requireNotNull(info.applicationInfo?.sourceDir) {
                            "Installed extension APK path is missing"
                        }
                        inspectMihonPackage(info, apkPath) + mapOf(
                            "displayName" to context.packageManager
                                .getApplicationLabel(requireNotNull(info.applicationInfo))
                                .toString()
                                .ifBlank { info.packageName },
                            "versionName" to info.versionName
                                ?.takeIf { it.isNotBlank() }
                                .orEmpty()
                                .ifBlank { versionCode(info).toString() },
                        )
                    }.getOrNull()
                }
                .sortedBy { it["displayName"].toString().lowercase() }
                .toList()
        }
    }

    private fun copyInstalledMihonExtension(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val packageName = call.argument<String>("packageName")
        val destinationPath = call.argument<String>("destinationPath")
        if (packageName.isNullOrBlank() || destinationPath.isNullOrBlank()) {
            result.error(
                "invalid-argument",
                "packageName and destinationPath are required",
                null,
            )
            return
        }
        runInspection(result) {
            val info = installedPackage(packageName)
            require(isMihonExtension(info)) { "Package is not a Mihon extension" }
            val source = File(
                requireNotNull(info.applicationInfo?.sourceDir) {
                    "Installed extension APK path is missing"
                },
            )
            require(source.isFile) { "Installed extension APK is missing" }
            val destination = File(destinationPath)
            val filesRoot = context.filesDir.canonicalFile
            val canonicalDestination = destination.canonicalFile
            require(
                canonicalDestination.path.startsWith(filesRoot.path + File.separator),
            ) { "Destination must be in application files storage" }
            require(!canonicalDestination.exists()) { "Destination already exists" }
            canonicalDestination.parentFile?.mkdirs()
            try {
                source.inputStream().use { input ->
                    canonicalDestination.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= MAX_MIHON_APK_BYTES) {
                                "Installed extension APK is too large"
                            }
                            output.write(buffer, 0, count)
                        }
                        output.flush()
                    }
                }
                inspectMihonApk(canonicalDestination.path)
            } catch (error: Throwable) {
                canonicalDestination.delete()
                throw error
            }
        }
    }

    private fun runInspection(
        result: MethodChannel.Result,
        operation: () -> Any,
    ) {
        val executor = inspector
        if (executor == null || executor.isShutdown) {
            result.error("bridge-closed", "plugin metadata bridge is closed", null)
            return
        }
        executor.execute {
            val response = runCatching(operation)
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
        return inspectMihonPackage(info, apkPath)
    }

    private fun inspectMihonPackage(
        info: PackageInfo,
        apkPath: String,
    ): Map<String, Any> {
        require(File(apkPath).isFile) { "APK file does not exist" }
        val applicationInfo = requireNotNull(info.applicationInfo) {
            "APK application metadata is missing"
        }
        val metadata = applicationInfo.metaData
        val declaredExtensionLib = metadataText(
            info = info,
            apkPath = apkPath,
            metadata = metadata,
            keys = EXTENSION_LIB_KEYS,
        )
        val extensionLib = normalizeMihonExtensionLib(
            declaredExtensionLib,
            info.versionName,
        )
            ?: throw IllegalArgumentException("Mihon extension ABI metadata is missing")
        val rawEntryClasses = metadataText(
            info = info,
            apkPath = apkPath,
            metadata = metadata,
            keys = ENTRY_CLASS_KEYS,
        ) ?: throw IllegalArgumentException("Mihon extension entry metadata is missing")
        val entryClasses = parseMihonEntryClasses(info.packageName, rawEntryClasses)
        require(entryClasses.isNotEmpty()) { "Mihon extension entry metadata is empty" }
        val signer = signingCertificates(info).singleOrNull()
            ?: throw IllegalArgumentException("APK must have exactly one current signer")
        return buildMap {
            put("packageName", info.packageName)
            put("signerSha256", sha256(signer.toByteArray()))
            put("versionCode", versionCode(info))
            put("apkPath", apkPath)
            put("extensionLib", extensionLib)
            put(
                "extensionLibSource",
                if (declaredExtensionLib == null) "versionName" else "manifest",
            )
            declaredExtensionLib?.let { put("declaredExtensionLib", it) }
            put("entryClasses", entryClasses)
        }
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(apkPath: String): PackageInfo? {
        val flags = packageInfoFlags()
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
    private fun installedPackage(packageName: String): PackageInfo {
        val flags = packageInfoFlags() or PackageManager.GET_CONFIGURATIONS
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(flags.toLong()),
            )
        } else {
            context.packageManager.getPackageInfo(packageName, flags)
        }
    }

    @Suppress("DEPRECATION")
    private fun installedPackages(): List<PackageInfo> {
        val flags = packageInfoFlags() or PackageManager.GET_CONFIGURATIONS
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getInstalledPackages(
                PackageManager.PackageInfoFlags.of(flags.toLong()),
            )
        } else {
            context.packageManager.getInstalledPackages(flags)
        }
    }

    private fun packageInfoFlags() =
        PackageManager.GET_META_DATA or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            }

    private fun isMihonExtension(info: PackageInfo): Boolean {
        val hasFeature = info.reqFeatures.orEmpty().any {
            it.name == MIHON_EXTENSION_FEATURE
        }
        val hasKnownPackagePrefix =
            info.packageName.startsWith(MIHON_EXTENSION_PACKAGE_PREFIX)
        return hasFeature || hasKnownPackagePrefix
    }

    private fun metadataText(
        info: PackageInfo,
        apkPath: String,
        metadata: Bundle?,
        keys: List<String>,
    ): String? {
        val raw = metadataValue(metadata, keys) ?: return null
        val value = when (raw) {
            is Int -> {
                if (raw == 0) return null
                runCatching {
                    val applicationInfo = requireNotNull(info.applicationInfo).apply {
                        sourceDir = apkPath
                        publicSourceDir = apkPath
                    }
                    context.packageManager
                        .getResourcesForApplication(applicationInfo)
                        .getString(raw)
                }.getOrNull()
            }
            else -> raw.toString()
        }
        return value?.trim()?.takeIf(String::isNotEmpty)
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
        private const val MIHON_EXTENSION_FEATURE = "tachiyomi.extension"
        private const val MIHON_EXTENSION_PACKAGE_PREFIX =
            "eu.kanade.tachiyomi.extension."
        private const val MAX_MIHON_APK_BYTES = 128L * 1024L * 1024L
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

private fun metadataValue(metadata: Bundle?, keys: List<String>): Any? =
    keys.firstNotNullOfOrNull { key -> metadata?.get(key) }

internal fun parseMihonEntryClasses(
    packageName: String,
    rawValue: String,
): List<String> {
    require(packageName.isNotBlank()) { "Mihon extension package name is missing" }
    return rawValue
        .split(Regex("""[;,\r\n]+"""))
        .map(String::trim)
        .filter(String::isNotEmpty)
        .map { value -> if (value.startsWith('.')) packageName + value else value }
        .onEach { className ->
            require(MIHON_ENTRY_CLASS_NAME.matches(className)) {
                "Mihon extension entry class is invalid"
            }
        }
        .distinct()
        .also { classes ->
            require(classes.isNotEmpty()) { "Mihon extension entry metadata is empty" }
        }
}

private val MIHON_ENTRY_CLASS_NAME = Regex(
    "[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)+",
)

internal fun normalizeMihonExtensionLib(
    metadataValue: Any?,
    versionName: String?,
): String? {
    val declared = metadataValue?.toString()?.trim()
    if (!declared.isNullOrEmpty()) {
        val normalized = Regex("""^(\d+)\.(\d+)(?:\.|$)""").find(declared)
        return normalized?.let { "${it.groupValues[1]}.${it.groupValues[2]}" } ?: declared
    }
    val match = Regex("""^(\d+)\.(\d+)(?:\.|$)""").find(versionName.orEmpty())
        ?: return null
    return "${match.groupValues[1]}.${match.groupValues[2]}"
}
