package dev.zic.zic

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val TRACE_EXPORT_REQUEST = 0x5A49
        private const val TRACE_EXPORT_CHANNEL = "dev.zic.zic/debug_trace_export"
        private const val STARTUP_CHANNEL = "dev.zic.zic/startup"
        private const val TAG = "zic.MainActivity"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val rhttpExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-startup-rhttp").apply { isDaemon = true }
        }
    private val startupLock = Any()
    private var rhttpPreparation: CompletableFuture<Unit>? = null
    private val attachedPluginNames = mutableSetOf<String>()
    private var configuredEngine: FlutterEngine? = null
    private var startupChannel: MethodChannel? = null
    private var pendingTraceResult: MethodChannel.Result? = null
    private var pendingTraceBytes: ByteArray? = null

    init {
        startupLog("activity-created")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        startupLog("activity-onCreate")
        warmupStartupStorageMetadata()
        super.onCreate(savedInstanceState)
        startupLog("activity-onCreate-complete")
    }

    /**
     * Warms only the directory metadata used by the Dart bootstrap. On a cold
     * install the first access to the app-private files directory can wake the
     * Android filesystem for hundreds of milliseconds; doing the same tiny
     * probes before the Flutter loading unit is linked lets that latency overlap
     * engine startup without reading or owning any application data here.
     */
    private fun warmupStartupStorageMetadata() {
        val root = File(applicationContext.filesDir, "zic")
        rhttpExecutor.execute {
            val startedAt = SystemClock.elapsedRealtime()
            val homeSnapshot = File(root, "home_projection_snapshot.json").exists()
            val preferences = File(root, "app_preferences.json").exists()
            startupLog(
                "startup-storage-metadata-warmup " +
                    "homeSnapshot=$homeSnapshot preferences=$preferences " +
                    "durationMs=${SystemClock.elapsedRealtime() - startedAt}",
            )
        }
    }

    /**
     * Supplies the app storage root as part of the initial Dart invocation.
     *
     * The first startup-channel round trip can be queued behind engine startup
     * work on a cold Android launch. Keeping this value in the entrypoint
     * arguments lets the bootstrap isolate resolve storage without a platform
     * channel call. The channel method remains below for older hosts and other
     * embedding entrypoints that do not provide this argument.
     */
    override fun getDartEntrypointArgs(): List<String> = listOf(
        "zic-application-support=${applicationContext.filesDir.absolutePath}",
        "zic-startup-storage-metadata-warmed",
    )

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        startupLog("engine-create-start")
        // FlutterEngine's implicit constructor automatically registers every
        // generated plugin before configureFlutterEngine() is called. That
        // path loads rhttp/JNI/media native libraries on the Android main
        // thread during the very first install. Own the engine explicitly so
        // only the startup channels exist until a feature attaches its plugin.
        return FlutterEngine(context.applicationContext, null, false).also {
            startupLog("engine-create-complete")
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = true

    override fun onStart() {
        super.onStart()
        startupLog("activity-onStart")
    }

    override fun onResume() {
        super.onResume()
        startupLog("activity-onResume")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        startupLog("activity-window-focus:$hasFocus")
    }

    override fun onFlutterUiDisplayed() {
        startupLog("flutter-ui-displayed")
        super.onFlutterUiDisplayed()
    }

    override fun onFlutterUiNoLongerDisplayed() {
        startupLog("flutter-ui-no-longer-displayed")
        super.onFlutterUiNoLongerDisplayed()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        startupLog("configureFlutterEngine-start")
        configuredEngine = flutterEngine
        // FlutterActivity's default implementation registers every generated
        // plugin before Dart main(). rhttp performs a synchronous Rust library
        // load and Android verifier setup from onAttachedToEngine. The jni
        // plugin also loads dartjni from its static initializer. Both can hold
        // the platform thread for seconds on a fresh install. Do not register
        // any generated app plugin here: even the media texture bridge and
        // plugin-host executors are optional until after the first frame. The
        // startup and trace channels below are the only channels needed before
        // that boundary. Plugins with a native runtime are attached only when
        // the feature that owns them is first used.
        startupChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STARTUP_CHANNEL,
        )
        startupChannel?.setMethodCallHandler(::handleStartup)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TRACE_EXPORT_CHANNEL,
        ).setMethodCallHandler(::handleTraceExport)
        startupLog("configureFlutterEngine-complete")
    }

    private fun registerPlugin(
        flutterEngine: FlutterEngine,
        name: String,
        plugin: FlutterPlugin,
    ): Throwable? {
        synchronized(startupLock) {
            if (attachedPluginNames.contains(name)) {
                return null
            }
        }
        try {
            flutterEngine.plugins.add(plugin)
            synchronized(startupLock) {
                attachedPluginNames.add(name)
            }
            return null
        } catch (error: Throwable) {
            Log.e(TAG, "Error registering plugin $name", error)
            return error
        }
    }

    private fun handleStartup(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method
        if (method == "applicationSupportPath") {
            Log.i(TAG, "startup-applicationSupportPath")
            result.success(applicationContext.filesDir.absolutePath)
            return
        }
        if (method == "attachPlugin") {
            val name = call.argument<String>("name")?.trim()
            if (name.isNullOrEmpty()) {
                result.error(
                    "attach-plugin-arguments",
                    "plugin name is required",
                    null,
                )
                return
            }
            Log.i(TAG, "startup-attachPlugin-start:$name")
            val error = attachPlugin(name)
            if (error == null) {
                Log.i(TAG, "startup-attachPlugin-complete:$name")
                result.success(null)
            } else {
                result.error(
                    "attach-plugin-failed",
                    error.message ?: error.javaClass.name,
                    error.javaClass.name,
                )
            }
            return
        }
        val future = when (call.method) {
            "prepareRhttpAndroid" -> synchronized(startupLock) {
                rhttpPreparation ?: CompletableFuture<Unit>().also { created ->
                    rhttpPreparation = created
                    rhttpExecutor.execute {
                        try {
                            initializeRhttpAndroid()
                            created.complete(Unit)
                        } catch (error: Throwable) {
                            created.completeExceptionally(error)
                        }
                    }
                }
            }
            else -> {
                result.notImplemented()
                return
            }
        }
        future.whenComplete { _, error ->
            mainHandler.post {
                if (error == null) {
                    result.success(null)
                } else {
                    val failure = error ?: IllegalStateException("$method failed")
                    val cause = failure.cause ?: failure
                    result.error(
                        "$method-failed",
                        cause.message ?: cause.javaClass.name,
                        cause.javaClass.name,
                    )
                }
            }
        }
    }

    private fun initializeRhttpAndroid() {
        Log.i(TAG, "startup-prepareRhttp-start")
        DeferredAndroidPlugins.prepareRhttp(applicationContext)
        Log.i(TAG, "startup-prepareRhttp-complete")
    }

    private fun attachPlugin(name: String): Throwable? {
        val engine = configuredEngine
            ?: return IllegalStateException("Flutter engine is not configured")
        synchronized(startupLock) {
            if (attachedPluginNames.contains(name)) {
                return null
            }
        }
        return try {
            val plugin = DeferredAndroidPlugins.create(name)
                ?: return IllegalArgumentException("unsupported deferred plugin: $name")
            registerPlugin(engine, name, plugin)
        } catch (error: Throwable) {
            Log.e(TAG, "Unable to create deferred plugin $name", error)
            error
        }
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

    private fun startupLog(event: String) {
        Log.i(TAG, "$event elapsedMs=${SystemClock.elapsedRealtime()}")
    }

    override fun onDestroy() {
        pendingTraceResult?.error(
            "trace-export-cancelled",
            "activity destroyed during trace export",
            null,
        )
        clearPendingTrace()
        startupChannel?.setMethodCallHandler(null)
        startupChannel = null
        configuredEngine = null
        rhttpExecutor.shutdownNow()
        super.onDestroy()
    }
}
