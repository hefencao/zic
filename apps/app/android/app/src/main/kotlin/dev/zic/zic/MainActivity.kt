package dev.zic.zic

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
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
        private const val DOWNLOAD_PICK_REQUEST = 0x5A4A
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
    private var pendingDownloadPick: MethodChannel.Result? = null

    private fun clearPendingDownloadPick() {
        pendingDownloadPick = null
    }


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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.zic.zic/saf_store",
        ).setMethodCallHandler(::handleSaf)
        startupLog("configureFlutterEngine-complete")
    }

    /**
     * SAF byte bridge. Owns a descriptor table of
     * [android.content.ContentResolver]-backed file handles so Dart gets
     * random-access reads/writes over SAF trees without any storage
     * permission: every descriptor derives from the persisted tree grant
     * taken by [pickDownloadDirectory].
     *
     * Methods: safOpen(treeUri, relativePath, mode=read|writeAppend|writeTruncate)
     * → handle; safRead(handle, length) → bytes (advances cursor);
     * safWrite(handle, bytes); safSeek(handle, position);
     * safLength(handle) → long; safClose(handle);
     * safDelete(treeUri, relativePath); safRename(treeUri, relativePath, newRelativePath);
     * safReplace(treeUri, relativePath, newRelativePath);
     * safExists(treeUri, relativePath).
     */
    private val safDescriptors = java.util.concurrent.ConcurrentHashMap<Int, android.os.ParcelFileDescriptor>()
    private val safNames = java.util.concurrent.ConcurrentHashMap<Int, String>()
    private val safCounter = java.util.concurrent.atomic.AtomicInteger(1)

    
    
    private val safExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-saf").apply { isDaemon = true }
        }

    private data class SafBridgeFailure(
        val code: String,
        val message: String,
    )

    private fun safBridgeFailure(error: Throwable): SafBridgeFailure {
        val code = when (error) {
            is SecurityException -> "saf-access-denied"
            is java.io.FileNotFoundException -> "saf-missing"
            is android.system.ErrnoException -> when (error.errno) {
                android.system.OsConstants.EACCES,
                android.system.OsConstants.EPERM -> "saf-access-denied"
                android.system.OsConstants.ENOENT -> "saf-missing"
                else -> "saf-io-failure"
            }
            is IllegalStateException -> if (error.message == "tree unavailable") {
                "saf-stale-locator"
            } else {
                "saf-io-failure"
            }
            else -> "saf-io-failure"
        }
        return SafBridgeFailure(code, error.message ?: error.javaClass.simpleName)
    }

    /**
     * SAF byte bridge. All DocumentFile/ContentResolver work runs on
     * [safExecutor]; results are posted back to the platform thread because
     * MethodChannel.Result is main-thread-only.
     */
    private fun handleSaf(call: MethodCall, result: MethodChannel.Result) {
        safExecutor.execute {
            val reply: Pair<Boolean, Any?> = try {
                when (call.method) {
                    "safOpen" -> runCatching { safOpen(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safRead" -> runCatching { safRead(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safWrite" -> runCatching { safWrite(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "safSeek" -> runCatching { safSeek(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "safLength" -> runCatching { safLength(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safClose" -> runCatching { safClose(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "safDelete" -> runCatching { safDelete(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safRename" -> runCatching { safRename(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safReplace" -> runCatching { safReplace(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safExists" -> runCatching { safExists(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safList" -> runCatching { safList(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    else -> false to "notImplemented"
                }
            } catch (error: Throwable) {
                false to safBridgeFailure(error)
            }
            val (ok, payload) = reply
            mainHandler.post {
                if (ok) {
                    result.success(payload)
                } else {
                    val failure = payload as? SafBridgeFailure
                    result.error(
                        failure?.code ?: "saf-io-failure",
                        failure?.message ?: "$payload",
                        null,
                    )
                }
            }
        }
    }

    private fun safTreeRoot(treeUri: String): androidx.documentfile.provider.DocumentFile? =
        androidx.documentfile.provider.DocumentFile.fromTreeUri(
            this,
            Uri.parse(treeUri),
        )

    private fun isSafeRelativePath(relativePath: String, allowRoot: Boolean = false): Boolean {
        if (allowRoot && relativePath.isEmpty()) return true
        if (relativePath.isEmpty() || relativePath.startsWith('/') || relativePath.contains('\\')) {
            return false
        }
        return relativePath.split('/').all { segment ->
            segment.isNotEmpty() && segment != "." && segment != ".."
        }
    }

    private fun resolvePath(root: androidx.documentfile.provider.DocumentFile, relativePath: String): androidx.documentfile.provider.DocumentFile? {
        if (!isSafeRelativePath(relativePath, allowRoot = true)) return null
        var dir = root
        for (segment in relativePath.split('/').filter { it.isNotEmpty() }) {
            val found = dir.findFile(segment) ?: return null
            dir = found
        }
        return dir
    }

    private fun safOpen(call: MethodCall): Int {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        require(isSafeRelativePath(relativePath)) { "unsafe relative path" }
        val mode = call.argument<String>("mode") ?: "read"
        require(mode == "read" || mode == "writeAppend" || mode == "writeTruncate") {
            "unsupported SAF open mode"
        }
        val root = safTreeRoot(treeUri)
            ?: throw IllegalStateException("tree unavailable")
        val target: androidx.documentfile.provider.DocumentFile =
            if (relativePath.isEmpty()) root else resolvePath(root, relativePath)
                ?: run {
                    if (mode == "read") throw java.io.FileNotFoundException("missing $relativePath")
                    var dir = root
                    val segments = relativePath.split('/').filter { it.isNotEmpty() }
                    for (i in segments.indices) {
                        val segment = segments[i]
                        val isLast = i == segments.lastIndex
                        val existing = dir.findFile(segment)
                        dir = existing ?: (if (isLast) {
                            val mimeType = when {
                                segment.endsWith(".jpg", ignoreCase = true) || segment.endsWith(".jpeg", ignoreCase = true) -> "image/jpeg"
                                segment.endsWith(".png", ignoreCase = true) -> "image/png"
                                segment.endsWith(".webp", ignoreCase = true) -> "image/webp"
                                segment.endsWith(".gif", ignoreCase = true) -> "image/gif"
                                segment.endsWith(".avif", ignoreCase = true) -> "image/avif"
                                else -> "application/octet-stream"
                            }
                            dir.createFile(mimeType, segment)
                        } else {
                            dir.createDirectory(segment)
                        }) ?: throw IllegalStateException("cannot create $segment")
                    }
                    dir
                }
        val pfd = contentResolver.openFileDescriptor(target.uri, if (mode == "read") "r" else "rw")
            ?: throw IllegalStateException("resolver returned null")
        if (mode == "writeTruncate") {
            android.system.Os.ftruncate(pfd.fileDescriptor, 0)
            android.system.Os.lseek(
                pfd.fileDescriptor,
                0,
                android.system.OsConstants.SEEK_SET,
            )
        } else if (mode == "writeAppend") {
            android.system.Os.lseek(
                pfd.fileDescriptor,
                0,
                android.system.OsConstants.SEEK_END,
            )
        }
        val handle = safCounter.getAndIncrement()
        safDescriptors[handle] = pfd
        return handle
    }

    private fun safDescriptor(call: MethodCall): android.os.ParcelFileDescriptor {
        val handle = requireNotNull(call.argument<Number>("handle")).toInt()
        return requireNotNull(safDescriptors[handle]) { "unknown handle" }
    }

    private fun safRead(call: MethodCall): ByteArray {
        val pfd = safDescriptor(call)
        val length = requireNotNull(call.argument<Number>("length")).toInt()
        require(length >= 0) { "read length must not be negative" }
        if (length == 0) return ByteArray(0)
        val buffer = ByteArray(minOf(length, 8 shl 20))
        val read = android.system.Os.read(pfd.fileDescriptor, buffer, 0, buffer.size)
        return if (read <= 0) ByteArray(0) else buffer.copyOf(read)
    }

    private fun safWrite(call: MethodCall) {
        val pfd = safDescriptor(call)
        val bytes = requireNotNull(call.argument<ByteArray>("bytes"))
        var offset = 0
        while (offset < bytes.size) {
            val written = android.system.Os.write(
                pfd.fileDescriptor,
                bytes,
                offset,
                bytes.size - offset,
            )
            require(written > 0) { "SAF write made no progress" }
            offset += written
        }
    }

    private fun safSeek(call: MethodCall) {
        val pfd = safDescriptor(call)
        val position = requireNotNull(call.argument<Number>("position")).toLong()
        android.system.Os.lseek(pfd.fileDescriptor, position, android.system.OsConstants.SEEK_SET)
    }

    private fun safLength(call: MethodCall): Long {
        val pfd = safDescriptor(call)
        val saved = android.system.Os.lseek(pfd.fileDescriptor, 0, android.system.OsConstants.SEEK_CUR)
        val size = android.system.Os.lseek(pfd.fileDescriptor, 0, android.system.OsConstants.SEEK_END)
        android.system.Os.lseek(pfd.fileDescriptor, saved, android.system.OsConstants.SEEK_SET)
        return size
    }

    private fun safClose(call: MethodCall) {
        val handle = call.argument<Number>("handle")?.toInt() ?: return
        safDescriptors.remove(handle)?.close()
    }

    private fun safDelete(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        if (!isSafeRelativePath(relativePath)) return false
        val root = safTreeRoot(treeUri) ?: return false
        return resolvePath(root, relativePath)?.delete() == true
    }

    private fun safRename(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = requireNotNull(call.argument<String>("relativePath"))
        val newRelativePath = requireNotNull(call.argument<String>("newRelativePath"))
        if (!isSafeRelativePath(relativePath) || !isSafeRelativePath(newRelativePath)) return false
        val root = safTreeRoot(treeUri) ?: return false
        val source = resolvePath(root, relativePath) ?: return false
        val segments = newRelativePath.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) return false
        val parentPath = segments.dropLast(1).joinToString("/")
        val parent = if (parentPath.isBlank()) {
            root
        } else {
            resolvePath(root, parentPath) ?: return false
        }
        // The temp-file commit protocol only renames within one directory.
        // Refuse an existing destination so callers can decide how to replace
        // it after the new bytes have been fully staged.
        if (parent.findFile(segments.last()) != null) return false
        return source.renameTo(segments.last())
    }

    /**
     * Commits a staged document only when the provider can rename into an
     * unused destination. Generic DocumentFile providers do not expose an
     * atomic overwrite primitive; returning false preserves the previous
     * document and lets the caller choose retry or save-as-new.
     */
    private fun safReplace(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = requireNotNull(call.argument<String>("relativePath"))
        val newRelativePath = requireNotNull(call.argument<String>("newRelativePath"))
        if (!isSafeRelativePath(relativePath) || !isSafeRelativePath(newRelativePath)) return false
        val root = safTreeRoot(treeUri) ?: return false
        val source = resolvePath(root, relativePath) ?: return false
        val segments = newRelativePath.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) return false
        val parentPath = segments.dropLast(1).joinToString("/")
        val parent = if (parentPath.isBlank()) {
            root
        } else {
            resolvePath(root, parentPath) ?: return false
        }
        val targetName = segments.last()
        val existing = parent.findFile(targetName)
        if (existing == null) return source.renameTo(targetName)
        if (existing.uri == source.uri) return true
        val backupName = "$targetName.zic-old-${System.nanoTime()}"
        if (!existing.renameTo(backupName)) return false
        val committed = source.renameTo(targetName)
        if (!committed) {
            val backup = parent.findFile(backupName)
            if (backup != null && parent.findFile(targetName) == null) {
                backup.renameTo(targetName)
            }
            return false
        }
        parent.findFile(backupName)?.delete()
        return true
    }

    private fun safExists(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        if (!isSafeRelativePath(relativePath, allowRoot = true)) return false
        val root = safTreeRoot(treeUri) ?: return false
        return resolvePath(root, relativePath) != null
    }

    private fun safList(call: MethodCall): List<Map<String, Any?>> {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        if (!isSafeRelativePath(relativePath, allowRoot = true)) return emptyList()
        val root = safTreeRoot(treeUri) ?: return emptyList()
        val target = if (relativePath.isEmpty()) root else resolvePath(root, relativePath) ?: return emptyList()
        if (!target.isDirectory) return emptyList()
        val files = target.listFiles()
        return files.map { file ->
            mapOf(
                "name" to file.name,
                "isDirectory" to file.isDirectory,
                "length" to file.length(),
            )
        }
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
        if (method == "pickDownloadDirectory") {
            if (pendingDownloadPick != null) {
                result.error("download-pick-busy", "another pick is active", null)
                return
            }
            pendingDownloadPick = result
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                )
            }
            try {
                @Suppress("DEPRECATION")
                startActivityForResult(intent, DOWNLOAD_PICK_REQUEST)
            } catch (error: Throwable) {
                clearPendingDownloadPick()
                result.error(
                    "download-pick-launch-failed",
                    error.message ?: error.javaClass.simpleName,
                    null,
                )
            }
            return
        }
        if (method == "openAllFilesAccessSettings") {
            val perApp = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val fallback = Intent(
                Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION,
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                startActivity(perApp)
                result.success(null)
            } catch (perAppError: Throwable) {
                try {
                    startActivity(fallback)
                    result.success(null)
                } catch (fallbackError: Throwable) {
                    result.error(
                        "open-all-files-settings-failed",
                        fallbackError.message ?: fallbackError.javaClass.name,
                        null,
                    )
                }
            }
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
        val mimeType = when {
            suggestedName.endsWith(".txt") || suggestedName.endsWith(".log") -> "text/plain"
            // application/json makes DocumentsUI normalize the title to the
            // canonical .json extension, turning name.jsonl into
            // name.jsonl.json. Generic binary keeps the suggested name intact.
            suggestedName.endsWith(".jsonl") || suggestedName.endsWith(".json") -> "application/octet-stream"
            else -> "*/*"
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, suggestedName)
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "text/plain",
                    "application/json",
                    "application/x-ndjson",
                    "application/octet-stream",
                    "*/*",
                ),
            )
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
        if (requestCode == DOWNLOAD_PICK_REQUEST) {
            val pending = pendingDownloadPick
            clearPendingDownloadPick()
            if (pending == null) return
            val uri: Uri? = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (error: Throwable) {
                Log.w(TAG, "persistable uri permission failed", error)
            }
            pending.success(uri.toString())
            return
        }
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
            val outputStream = try {
                contentResolver.openOutputStream(uri, "wt")
            } catch (_: Throwable) {
                contentResolver.openOutputStream(uri, "w")
            }
            outputStream.use { output ->
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
        pendingDownloadPick?.error(
            "download-pick-cancelled",
            "activity destroyed during directory pick",
            null,
        )
        clearPendingDownloadPick()
        startupChannel?.setMethodCallHandler(null)
        startupChannel = null
        configuredEngine = null
        rhttpExecutor.shutdownNow()
        super.onDestroy()
    }
}
