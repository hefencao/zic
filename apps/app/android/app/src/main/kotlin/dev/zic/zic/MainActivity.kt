package dev.zic.zic

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        private const val TRACE_EXPORT_REQUEST = 0x5A49
        private const val DOWNLOAD_PICK_REQUEST = 0x5A4A
        private const val TRACE_EXPORT_CHANNEL = "dev.zic.zic/debug_trace_export"
        private const val STARTUP_CHANNEL = "dev.zic.zic/startup"
        private const val TAG = "zic.MainActivity"
        private const val SAF_LOCATOR_PREFS = "zic_saf_locator_cache"
        private const val SAF_LOCATOR_STATE = "recent_exact_document_ids_v1"
        private const val SAF_LOCATOR_MAX_ENTRIES = 256
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
    // ACTION_CREATE_DOCUMENT normally returns through onActivityResult before
    // this Activity resumes. Root-back now keeps the Activity/engine alive, so
    // a provider/OEM path that resumes us without delivering that callback
    // must not leave one MethodChannel result permanently blocking every later
    // export attempt.
    private var traceExportHostPaused = false
    private var pendingDownloadPick: MethodChannel.Result? = null
    private var firstFlutterUiDisplayed = false
    private var pendingFirstFlutterUiDisplayedResult: MethodChannel.Result? = null
    private val processStartElapsedRealtimeMs = android.os.Process.getStartElapsedRealtime()
    private val nativeStartupTimeline = mutableListOf<Map<String, Any>>()

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

    override fun onPause() {
        if (pendingTraceResult != null) {
            traceExportHostPaused = true
            startupLog("trace-export-host-paused")
        }
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        startupLog("activity-onResume")
        // For startActivityForResult the normal result callback is dispatched
        // before onResume. If we get here after the picker paused us and the
        // pending result is still present, the external round-trip has been
        // abandoned/lost. Clear it now so a retained Activity cannot poison all
        // future export attempts.
        if (traceExportHostPaused && pendingTraceResult != null) {
            val stale = pendingTraceResult
            clearPendingTrace()
            startupLog("trace-export-missing-result-cleared")
            stale?.error(
                "trace-export-cancelled",
                "document picker returned without an activity result",
                null,
            )
        }
        traceExportHostPaused = false
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        startupLog("activity-window-focus:$hasFocus")
    }

    override fun onFlutterUiDisplayed() {
        startupLog("flutter-ui-displayed")
        firstFlutterUiDisplayed = true
        pendingFirstFlutterUiDisplayedResult?.success(true)
        pendingFirstFlutterUiDisplayedResult = null
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
     * safReadAt(handle, position, length) → bytes (one random-access operation);
     * safWrite(handle, bytes); safSeek(handle, position);
     * safLength(handle) → long; safClose(handle);
     * safDelete(treeUri, relativePath); safRename(treeUri, relativePath, newRelativePath);
     * safExists(treeUri, relativePath).
     */
    private val safDescriptors = java.util.concurrent.ConcurrentHashMap<Int, android.os.ParcelFileDescriptor>()
    private val safNames = java.util.concurrent.ConcurrentHashMap<Int, String>()
    private val safCounter = java.util.concurrent.atomic.AtomicInteger(1)

    
    
    /// Serializes SAF tree/path resolution and namespace mutation. These
    /// operations may walk DocumentFile/provider metadata and therefore must
    /// not sit in front of reads on descriptors that are already open.
    private val safExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-saf-path").apply { isDaemon = true }
        }

    private val localReadOpenThreadCounter = java.util.concurrent.atomic.AtomicInteger(0)
    private val localReadOpenExecutor: ExecutorService =
        Executors.newFixedThreadPool(4) { runnable ->
            val index = localReadOpenThreadCounter.getAndIncrement()
            Thread(runnable, "zic-local-read-open-$index").apply { isDaemon = true }
        }

    private val safNamespaceLock = java.util.concurrent.locks.ReentrantReadWriteLock()

    private inline fun <T> withSafNamespaceRead(block: () -> T): T {
        val lock = safNamespaceLock.readLock()
        lock.lock()
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }

    private inline fun <T> withSafNamespaceWrite(block: () -> T): T {
        val lock = safNamespaceLock.writeLock()
        lock.lock()
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }

    /// Byte operations are striped by descriptor handle. One handle keeps strict
    /// submission order (seek/read/write/close cannot race), while unrelated
    /// read-only files may progress in parallel. Dart's ArtifactCacheReadScheduler
    /// remains the admission/priority owner; these lanes only avoid serializing
    /// independent descriptors behind one platform FIFO.
    private val safDescriptorExecutors: List<ExecutorService> =
        List(4) { index ->
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "zic-saf-descriptor-$index").apply { isDaemon = true }
            }
        }

    private fun safDescriptorExecutorFor(call: MethodCall): ExecutorService {
        val handle = call.argument<Number>("handle")?.toInt() ?: 0
        return safDescriptorExecutors[Math.floorMod(handle, safDescriptorExecutors.size)]
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
     * SAF byte bridge. Tree/path operations remain serialized on [safExecutor].
     * Operations on an already-open descriptor are striped by handle across
     * [safDescriptorExecutors]: one handle stays ordered, independent files may
     * run concurrently. Results are posted back to the platform thread because
     * MethodChannel.Result is main-thread-only.
     */
    private fun handleSaf(call: MethodCall, result: MethodChannel.Result) {
        val executor = when (call.method) {
            "safOpen" -> if ((call.argument<String>("mode") ?: "read") == "read") {
                localReadOpenExecutor
            } else {
                safExecutor
            }
            "safPrewarmRecentRead",
            "presentationOpenDirect",
            "presentationOpenSaf" -> localReadOpenExecutor
            "safRead",
            "safReadAt",
            "safWrite",
            "safSeek",
            "safLength",
            "safClose",
            "presentationClose" -> safDescriptorExecutorFor(call)
            else -> safExecutor
        }
        executor.execute {
            val reply: Pair<Boolean, Any?> = try {
                when (call.method) {
                    "safOpen" -> runCatching { safOpen(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safPrewarmRecentRead" -> runCatching { safPrewarmRecentRead(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safRead" -> runCatching { safRead(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safReadAt" -> runCatching { safReadAt(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safWrite" -> runCatching { safWrite(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "safSeek" -> runCatching { safSeek(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "safLength" -> runCatching { safLength(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safClose" -> runCatching { safClose(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "presentationOpenDirect" -> runCatching { presentationOpenDirect(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "presentationOpenSaf" -> runCatching { presentationOpenSaf(call) }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "presentationClose" -> runCatching { safClose(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "presentationCloseMany" -> runCatching { presentationCloseMany(call) }
                        .fold({ true to null }, { false to safBridgeFailure(it) })
                    "safDelete" -> runCatching { withSafNamespaceWrite { safDelete(call) } }
                        .fold({ true to it }, { false to safBridgeFailure(it) })
                    "safRename" -> runCatching { withSafNamespaceWrite { safRename(call) } }
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

    // Accessed only from the single SAF executor. Each entry is one directory
    // listing keyed by provider document id, so hundreds of sibling pages pay
    // one children query instead of repeating DocumentFile.findFile metadata
    // lookups for every page open.
    private val safChildDocumentIds =
        java.util.concurrent.ConcurrentHashMap<String, Map<String, String>>()

    // Process restarts lose the directory-listing cache above. Keep only a
    // bounded set of exact provider document ids that have already opened
    // successfully. Document ids are opaque acceleration hints, never file
    // existence authority: a stale direct open is discarded and immediately
    // falls back to the normal tree traversal below.
    private val safExactDocumentIds = java.util.LinkedHashMap<String, String>(
        SAF_LOCATOR_MAX_ENTRIES + 1,
        0.75f,
        true,
    )
    private val safExactDocumentIdsLock = Any()
    private var safExactDocumentIdsLoaded = false

    private fun safExactLocatorKey(treeUri: String, relativePath: String): String =
        "$treeUri\u0000$relativePath"

    private fun normalizeLegacySafExactLocatorKey(key: String): String {
        val separator = key.indexOf('\u0000')
        if (separator <= 0) return key
        val treeUri = key.substring(0, separator)
        if (!treeUri.startsWith("/content://")) return key
        return key.substring(1)
    }

    private fun ensureSafExactDocumentIdsLoaded() {
        synchronized(safExactDocumentIdsLock) {
            if (safExactDocumentIdsLoaded) return
            safExactDocumentIdsLoaded = true
            val encoded = getSharedPreferences(SAF_LOCATOR_PREFS, Context.MODE_PRIVATE)
                .getString(SAF_LOCATOR_STATE, null) ?: return
            try {
                val entries = JSONArray(encoded)
                val start = maxOf(0, entries.length() - SAF_LOCATOR_MAX_ENTRIES)
                var repairedLegacyTreeKey = false
                for (index in start until entries.length()) {
                    val entry = entries.optJSONObject(index) ?: continue
                    val key = entry.optString("key")
                    val documentId = entry.optString("documentId")
                    if (key.isNotEmpty() && documentId.isNotEmpty()) {
                        val normalizedKey = normalizeLegacySafExactLocatorKey(key)
                        repairedLegacyTreeKey = repairedLegacyTreeKey || normalizedKey != key
                        safExactDocumentIds[normalizedKey] = documentId
                    }
                }
                if (repairedLegacyTreeKey) {
                    // Acceleration-only metadata from the historical saf://
                    // prefix off-by-one used `/content://...` as its tree key.
                    // The opaque document id remains a hint: a stale id still
                    // falls back to normal provider path resolution on open.
                    val repairedEntries = JSONArray()
                    for ((key, documentId) in safExactDocumentIds) {
                        repairedEntries.put(
                            JSONObject()
                                .put("key", key)
                                .put("documentId", documentId),
                        )
                    }
                    getSharedPreferences(SAF_LOCATOR_PREFS, Context.MODE_PRIVATE)
                        .edit()
                        .putString(SAF_LOCATOR_STATE, repairedEntries.toString())
                        .apply()
                }
            } catch (_: Throwable) {
                safExactDocumentIds.clear()
            }
        }
    }

    private fun persistSafExactDocumentIds() {
        val encoded = synchronized(safExactDocumentIdsLock) {
            val entries = JSONArray()
            for ((key, documentId) in safExactDocumentIds) {
                entries.put(
                    JSONObject()
                        .put("key", key)
                        .put("documentId", documentId),
                )
            }
            entries.toString()
        }
        getSharedPreferences(SAF_LOCATOR_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(SAF_LOCATOR_STATE, encoded)
            .apply()
    }

    private fun cachedSafExactDocumentId(
        treeUri: String,
        relativePath: String,
    ): String? = synchronized(safExactDocumentIdsLock) {
        ensureSafExactDocumentIdsLoaded()
        safExactDocumentIds[safExactLocatorKey(treeUri, relativePath)]
    }

    private fun rememberSafExactDocumentId(
        treeUri: String,
        relativePath: String,
        documentId: String,
    ) {
        val changed = synchronized(safExactDocumentIdsLock) {
            ensureSafExactDocumentIdsLoaded()
            val key = safExactLocatorKey(treeUri, relativePath)
            val unchanged = safExactDocumentIds[key] == documentId
            safExactDocumentIds[key] = documentId
            if (!unchanged) {
                while (safExactDocumentIds.size > SAF_LOCATOR_MAX_ENTRIES) {
                    val eldest = safExactDocumentIds.entries.iterator().next()
                    safExactDocumentIds.remove(eldest.key)
                }
            }
            !unchanged
        }
        if (changed) persistSafExactDocumentIds()
    }

    private fun forgetSafExactLocator(
        treeUri: String,
        relativePath: String,
        includeDescendants: Boolean = false,
    ) {
        val changed = synchronized(safExactDocumentIdsLock) {
            ensureSafExactDocumentIdsLoaded()
            val key = safExactLocatorKey(treeUri, relativePath)
            var removed = safExactDocumentIds.remove(key) != null
            if (includeDescendants) {
                val prefix = "$key/"
                val staleKeys = safExactDocumentIds.keys
                    .filter { it.startsWith(prefix) }
                for (staleKey in staleKeys) {
                    removed = safExactDocumentIds.remove(staleKey) != null || removed
                }
            }
            removed
        }
        if (changed) persistSafExactDocumentIds()
    }

    private fun clearSafPathCache(treeUri: String? = null) {
        if (treeUri == null) {
            safChildDocumentIds.clear()
            return
        }
        val prefix = "$treeUri\u0000"
        safChildDocumentIds.keys.removeAll { it.startsWith(prefix) }
    }

    private fun safChildCacheKey(treeUri: String, parentDocumentId: String): String =
        "$treeUri\u0000$parentDocumentId"

    private fun documentIdForSafUri(uri: Uri): String? = try {
        DocumentsContract.getDocumentId(uri)
    } catch (_: Throwable) {
        null
    }

    private fun forgetSafDirectoryListing(
        treeUri: String,
        parentDocumentId: String?,
    ) {
        if (parentDocumentId == null) return
        safChildDocumentIds.remove(safChildCacheKey(treeUri, parentDocumentId))
    }

    private fun invalidateSafDirectoryListing(
        treeUri: String,
        parentDocumentId: String?,
    ) {
        if (parentDocumentId == null) {
            clearSafPathCache(treeUri)
            return
        }
        forgetSafDirectoryListing(treeUri, parentDocumentId)
    }

    private fun invalidateSafDirectoryListing(
        treeUri: String,
        directory: androidx.documentfile.provider.DocumentFile,
    ) {
        invalidateSafDirectoryListing(treeUri, documentIdForSafUri(directory.uri))
    }

    private fun parentRelativePath(relativePath: String): String {
        val segments = relativePath.split('/').filter { it.isNotEmpty() }
        return segments.dropLast(1).joinToString("/")
    }

    private fun invalidateSafReadParentListing(
        treeUriText: String,
        relativePath: String,
    ): Boolean {
        val treeUri = Uri.parse(treeUriText)
        val parentPath = parentRelativePath(relativePath)
        val parentDocumentId = if (parentPath.isEmpty()) {
            try {
                DocumentsContract.getTreeDocumentId(treeUri)
            } catch (_: Throwable) {
                null
            }
        } else {
            resolveReadDocumentId(treeUriText, parentPath)
        } ?: return false
        safChildDocumentIds.remove(safChildCacheKey(treeUriText, parentDocumentId))
        return true
    }

    private fun childDocumentId(
        treeUri: Uri,
        parentDocumentId: String,
        displayName: String,
    ): String? {
        val key = safChildCacheKey(treeUri.toString(), parentDocumentId)
        val indexed = safChildDocumentIds.computeIfAbsent(key) {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                parentDocumentId,
            )
            val values = LinkedHashMap<String, String>()
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                ),
                null,
                null,
                null,
            )?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                )
                val nameColumn = cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                )
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameColumn) ?: continue
                    val id = cursor.getString(idColumn) ?: continue
                    values.putIfAbsent(name, id)
                }
            }
            values.toMap()
        }
        return indexed[displayName]
    }

    private fun resolveReadDocumentId(
        treeUriText: String,
        relativePath: String,
    ): String? {
        if (!isSafeRelativePath(relativePath)) return null
        val treeUri = Uri.parse(treeUriText)
        var documentId = DocumentsContract.getTreeDocumentId(treeUri)
        for (segment in relativePath.split('/').filter { it.isNotEmpty() }) {
            documentId = childDocumentId(treeUri, documentId, segment) ?: return null
        }
        return documentId
    }

    private fun resolveReadUri(treeUriText: String, relativePath: String): Uri? {
        val documentId = resolveReadDocumentId(treeUriText, relativePath) ?: return null
        return DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUriText), documentId)
    }

    private fun openSafReadDescriptor(
        treeUri: String,
        relativePath: String,
    ): android.os.ParcelFileDescriptor = withSafNamespaceRead {
        openSafReadDescriptorUnlocked(treeUri, relativePath)
    }

    private fun openSafReadDescriptorUnlocked(
        treeUri: String,
        relativePath: String,
    ): android.os.ParcelFileDescriptor {
        val parsedTreeUri = Uri.parse(treeUri)

        fun openDocumentId(documentId: String): android.os.ParcelFileDescriptor {
            val uri = DocumentsContract.buildDocumentUriUsingTree(
                parsedTreeUri,
                documentId,
            )
            return contentResolver.openFileDescriptor(uri, "r")
                ?: throw IllegalStateException("resolver returned null")
        }

        val cachedDocumentId = cachedSafExactDocumentId(treeUri, relativePath)
        if (cachedDocumentId != null) {
            try {
                return openDocumentId(cachedDocumentId)
            } catch (_: java.io.FileNotFoundException) {
                forgetSafExactLocator(treeUri, relativePath)
                invalidateSafReadParentListing(treeUri, relativePath)
            }
        }

        fun resolveAndOpen(): android.os.ParcelFileDescriptor {
            val documentId = resolveReadDocumentId(treeUri, relativePath)
                ?: throw java.io.FileNotFoundException("missing $relativePath")
            val descriptor = openDocumentId(documentId)
            rememberSafExactDocumentId(treeUri, relativePath, documentId)
            return descriptor
        }

        return try {
            resolveAndOpen()
        } catch (error: java.io.FileNotFoundException) {
            // A user or another process may replace a document while this app
            // remains alive. Drop provider ids and resolve once from fresh
            // directory authority before surfacing the stale locator.
            forgetSafExactLocator(treeUri, relativePath)
            clearSafPathCache(treeUri)
            resolveAndOpen()
        }
    }

    private fun safPrewarmRecentRead(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val keyPrefix = "$treeUri\u0000"
        val documentId = synchronized(safExactDocumentIdsLock) {
            ensureSafExactDocumentIdsLoaded()
            safExactDocumentIds.entries
                .toList()
                .asReversed()
                .firstOrNull { (key, _) -> key.startsWith(keyPrefix) }
                ?.value
        } ?: return false
        return withSafNamespaceRead {
            runCatching {
                val uri = DocumentsContract.buildDocumentUriUsingTree(
                    Uri.parse(treeUri),
                    documentId,
                )
                contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                    // Touch descriptor metadata without reading body bytes. The
                    // descriptor is closed before this acceleration completes.
                    val statSize = descriptor.statSize
                    if (statSize < 0L) {
                        android.system.Os.fstat(descriptor.fileDescriptor).st_size
                    }
                } ?: return@runCatching false
                true
            }.getOrDefault(false)
        }
    }

    private fun safOpen(call: MethodCall): Int {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        require(isSafeRelativePath(relativePath)) { "unsafe relative path" }
        val mode = call.argument<String>("mode") ?: "read"
        require(mode == "read" || mode == "writeAppend" || mode == "writeTruncate") {
            "unsupported SAF open mode"
        }
        val pfd = if (mode == "read") {
            openSafReadDescriptor(treeUri, relativePath)
        } else withSafNamespaceWrite {
            val root = safTreeRoot(treeUri)
                ?: throw IllegalStateException("tree unavailable")
            val target: androidx.documentfile.provider.DocumentFile =
                resolvePath(root, relativePath) ?: run {
                    var dir = root
                    val segments = relativePath.split('/').filter { it.isNotEmpty() }
                    for (i in segments.indices) {
                        val segment = segments[i]
                        val isLast = i == segments.lastIndex
                        val existing = dir.findFile(segment)
                        if (existing != null) {
                            dir = existing
                            continue
                        }
                        val parent = dir
                        val created = (if (isLast) {
                            val mimeType = when {
                                segment.endsWith(".jpg", ignoreCase = true) || segment.endsWith(".jpeg", ignoreCase = true) -> "image/jpeg"
                                segment.endsWith(".png", ignoreCase = true) -> "image/png"
                                segment.endsWith(".webp", ignoreCase = true) -> "image/webp"
                                segment.endsWith(".gif", ignoreCase = true) -> "image/gif"
                                segment.endsWith(".avif", ignoreCase = true) -> "image/avif"
                                else -> "application/octet-stream"
                            }
                            parent.createFile(mimeType, segment)
                        } else {
                            parent.createDirectory(segment)
                        }) ?: throw IllegalStateException("cannot create $segment")
                        val createdRelativePath = segments.take(i + 1).joinToString("/")
                        forgetSafExactLocator(
                            treeUri,
                            createdRelativePath,
                            includeDescendants = !isLast,
                        )
                        invalidateSafDirectoryListing(treeUri, parent)
                        dir = created
                    }
                    dir
                }
            // Each created segment invalidates only its parent listing above.
            contentResolver.openFileDescriptor(target.uri, "rw")
                ?: throw IllegalStateException("resolver returned null")
        }
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

    private fun registerPresentationDescriptor(
        pfd: android.os.ParcelFileDescriptor,
    ): Map<String, Any> {
        val length = pfd.statSize.takeIf { it >= 0L }
            ?: android.system.Os.fstat(pfd.fileDescriptor).st_size
        require(length >= 0L) { "presentation descriptor length is unavailable" }
        val handle = safCounter.getAndIncrement()
        safDescriptors[handle] = pfd
        return mapOf(
            "handle" to handle,
            "path" to "/proc/self/fd/${pfd.fd}",
            "length" to length,
        )
    }

    private fun presentationOpenDirect(call: MethodCall): Map<String, Any> {
        val path = requireNotNull(call.argument<String>("path")).trim()
        require(path.isNotEmpty()) { "presentation path is required" }
        val file = java.io.File(path)
        require(file.isAbsolute && file.isFile) { "presentation file is unavailable" }
        val pfd = android.os.ParcelFileDescriptor.open(
            file,
            android.os.ParcelFileDescriptor.MODE_READ_ONLY,
        )
        return try {
            registerPresentationDescriptor(pfd)
        } catch (error: Throwable) {
            pfd.close()
            throw error
        }
    }

    private fun presentationOpenSaf(call: MethodCall): Map<String, Any> {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        require(isSafeRelativePath(relativePath)) { "unsafe relative path" }
        val pfd = openSafReadDescriptor(treeUri, relativePath)
        return try {
            registerPresentationDescriptor(pfd)
        } catch (error: Throwable) {
            pfd.close()
            throw error
        }
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

    private fun safReadAt(call: MethodCall): ByteArray {
        val pfd = safDescriptor(call)
        val position = requireNotNull(call.argument<Number>("position")).toLong()
        val length = requireNotNull(call.argument<Number>("length")).toInt()
        require(position >= 0) { "read position must not be negative" }
        require(length >= 0) { "read length must not be negative" }
        if (length == 0) return ByteArray(0)
        val buffer = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = android.system.Os.pread(
                pfd.fileDescriptor,
                buffer,
                offset,
                length - offset,
                position + offset,
            )
            if (read <= 0) break
            offset += read
        }
        return if (offset == length) buffer else buffer.copyOf(offset)
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
        val statSize = pfd.statSize
        return if (statSize >= 0L) statSize else android.system.Os.fstat(pfd.fileDescriptor).st_size
    }

    private fun safClose(call: MethodCall) {
        val handle = call.argument<Number>("handle")?.toInt() ?: return
        safDescriptors.remove(handle)?.close()
    }

    private fun presentationCloseMany(call: MethodCall) {
        val handles = call.argument<List<Number>>("handles") ?: return
        var firstFailure: Throwable? = null
        for (value in handles) {
            val descriptor = safDescriptors.remove(value.toInt()) ?: continue
            try {
                descriptor.close()
            } catch (error: Throwable) {
                if (firstFailure == null) firstFailure = error
            }
        }
        firstFailure?.let { throw it }
    }

    private fun safDelete(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        if (!isSafeRelativePath(relativePath)) return false
        val root = safTreeRoot(treeUri) ?: return false
        val target = resolvePath(root, relativePath)
        if (target == null) {
            forgetSafExactLocator(treeUri, relativePath, includeDescendants = true)
            invalidateSafReadParentListing(treeUri, relativePath)
            return false
        }
        val parentPath = parentRelativePath(relativePath)
        val parent = if (parentPath.isEmpty()) root else resolvePath(root, parentPath)
        val targetDocumentId = documentIdForSafUri(target.uri)
        val deleted = target.delete()
        if (!deleted) return false
        forgetSafExactLocator(treeUri, relativePath, includeDescendants = true)
        if (parent != null) invalidateSafDirectoryListing(treeUri, parent)
        forgetSafDirectoryListing(treeUri, targetDocumentId)
        return true
    }

    private fun safRename(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = requireNotNull(call.argument<String>("relativePath"))
        val newRelativePath = requireNotNull(call.argument<String>("newRelativePath"))
        if (!isSafeRelativePath(relativePath) || !isSafeRelativePath(newRelativePath)) return false
        val root = safTreeRoot(treeUri) ?: return false
        val source = resolvePath(root, relativePath) ?: return false
        val sourceParentPath = parentRelativePath(relativePath)
        val sourceParent = if (sourceParentPath.isEmpty()) {
            root
        } else {
            resolvePath(root, sourceParentPath) ?: return false
        }
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
        val renamed = source.renameTo(segments.last())
        if (!renamed) return false
        forgetSafExactLocator(treeUri, relativePath, includeDescendants = true)
        forgetSafExactLocator(treeUri, newRelativePath, includeDescendants = true)
        invalidateSafDirectoryListing(treeUri, sourceParent)
        if (parent.uri != sourceParent.uri) {
            invalidateSafDirectoryListing(treeUri, parent)
        }
        return true
    }


    private fun safExists(call: MethodCall): Boolean {
        val treeUri = requireNotNull(call.argument<String>("treeUri"))
        val relativePath = call.argument<String>("relativePath") ?: ""
        if (!isSafeRelativePath(relativePath, allowRoot = true)) return false
        if (relativePath.isEmpty()) return safTreeRoot(treeUri) != null
        return resolveReadUri(treeUri, relativePath) != null
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

    private fun allFilesAccessGranted(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            Environment.isExternalStorageManager()

    private fun directPathForSafTree(treeUri: String): String? {
        if (!allFilesAccessGranted()) return null
        val uri = runCatching { Uri.parse(treeUri) }.getOrNull() ?: return null
        if (uri.scheme != "content" ||
            uri.authority != "com.android.externalstorage.documents") {
            return null
        }
        val documentId = runCatching {
            DocumentsContract.getTreeDocumentId(uri)
        }.getOrNull() ?: return null
        return runCatching {
            @Suppress("DEPRECATION")
            val primaryRoot = Environment.getExternalStorageDirectory()
            val storageManager = getSystemService(StorageManager::class.java)
            val volumes = storageManager.storageVolumes.map { volume ->
                ExternalStorageVolumeRoot(
                    uuid = volume.uuid,
                    directory = volume.directory,
                )
            }
            resolveExternalStorageTreeDirectPath(
                documentId = documentId,
                primaryRoot = primaryRoot,
                volumes = volumes,
            )
        }.getOrNull()
    }

    private fun directProbeTarget(call: MethodCall): File? {
        if (!allFilesAccessGranted()) return null
        val rootPath = call.argument<String>("directPath")?.trim() ?: return null
        val relativeName = call.argument<String>("relativeName") ?: return null
        if (!relativeName.startsWith(".zic-root-proof-") ||
            relativeName.contains('/') ||
            relativeName.contains('\\') ||
            relativeName == "." ||
            relativeName == "..") {
            return null
        }
        val root = runCatching { File(rootPath).canonicalFile }.getOrNull() ?: return null
        if (!root.isDirectory) return null
        val target = runCatching { File(root, relativeName).canonicalFile }.getOrNull() ?: return null
        return if (target.parentFile == root) target else null
    }

    private fun createDirectProbeFileExclusive(call: MethodCall): Boolean {
        val target = directProbeTarget(call) ?: return false
        val bytes = call.argument<ByteArray>("bytes") ?: return false
        var created = false
        return try {
            val descriptor = Os.open(
                target.path,
                OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_WRONLY,
                0x180, // 0600
            )
            created = true
            FileOutputStream(descriptor).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
            true
        } catch (_: Throwable) {
            if (created) runCatching { target.delete() }
            false
        }
    }

    private fun readDirectProbeFile(call: MethodCall): ByteArray? {
        val target = directProbeTarget(call) ?: return null
        return runCatching {
            if (!target.isFile || target.length() > 512L) null else target.readBytes()
        }.getOrNull()
    }

    private fun deleteDirectProbeFile(call: MethodCall): Boolean {
        val target = directProbeTarget(call) ?: return false
        return runCatching { !target.exists() || target.delete() }.getOrDefault(false)
    }

    private fun runtimeSchedulingSnapshot(): Map<String, Any?> {
        val status = runCatching { File("/proc/self/status").readLines() }
            .getOrDefault(emptyList())
        val cgroup = runCatching { File("/proc/self/cgroup").readLines() }
            .getOrDefault(emptyList())
        fun statusValue(name: String): String? = status
            .firstOrNull { it.startsWith("$name:") }
            ?.substringAfter(':')
            ?.trim()
        fun cgroupValue(controller: String): String? = cgroup
            .firstOrNull { line ->
                val fields = line.split(':', limit = 3)
                fields.size == 3 && fields[1].split(',').contains(controller)
            }
            ?.substringAfterLast(':')
        val processInfo = android.app.ActivityManager.RunningAppProcessInfo()
        android.app.ActivityManager.getMyMemoryState(processInfo)
        val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val miuiPowerSaveModeOpen = Settings.System.getInt(
            contentResolver,
            "POWER_SAVE_MODE_OPEN",
            0,
        ) != 0
        val globalLowPowerMode = Settings.Global.getInt(
            contentResolver,
            "low_power",
            0,
        ) != 0
        return mapOf(
            "powerSaveMode" to powerManager.isPowerSaveMode,
            "miuiPowerSaveModeOpen" to miuiPowerSaveModeOpen,
            "globalLowPowerMode" to globalLowPowerMode,
            "processImportance" to processInfo.importance,
            "cpuAllowedList" to statusValue("Cpus_allowed_list"),
            "cpusetGroup" to cgroupValue("cpuset"),
            "cpuGroup" to cgroupValue("cpu"),
            "availableProcessors" to Runtime.getRuntime().availableProcessors(),
            "elapsedRealtimeMs" to SystemClock.elapsedRealtime(),
        )
    }

    private fun handleStartup(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method
        if (method == "applicationSupportPath") {
            Log.i(TAG, "startup-applicationSupportPath")
            result.success(applicationContext.filesDir.absolutePath)
            return
        }
        if (method == "waitForFirstFlutterUiDisplayed") {
            if (firstFlutterUiDisplayed) {
                result.success(true)
                return
            }
            if (pendingFirstFlutterUiDisplayedResult != null) {
                result.error(
                    "startup-ui-wait-busy",
                    "first Flutter UI display wait is already active",
                    null,
                )
                return
            }
            pendingFirstFlutterUiDisplayedResult = result
            return
        }
        if (method == "runtimeSchedulingSnapshot") {
            result.success(runtimeSchedulingSnapshot())
            return
        }
        if (method == "nativeStartupTimeline") {
            val now = SystemClock.elapsedRealtime()
            val events = synchronized(nativeStartupTimeline) {
                nativeStartupTimeline.map { HashMap(it) }
            }
            result.success(
                mapOf(
                    "processStartElapsedRealtimeMs" to processStartElapsedRealtimeMs,
                    "retrievedElapsedRealtimeMs" to now,
                    "retrievedSinceProcessStartMs" to (now - processStartElapsedRealtimeMs),
                    "events" to events,
                ),
            )
            return
        }
        if (method == "moveApplicationToBackground") {
            // Root-back is navigation, not application shutdown. Keep this
            // Activity/FlutterEngine and every Dart owner alive, and let
            // Android move the existing task behind the launcher immediately.
            val moved = moveTaskToBack(true)
            startupLog("application-background-request moved=$moved")
            result.success(moved)
            return
        }
        if (method == "allFilesAccessGranted") {
            result.success(allFilesAccessGranted())
            return
        }
        if (method == "directPathForSafTree") {
            val treeUri = call.argument<String>("treeUri")?.trim()
            result.success(
                if (treeUri.isNullOrEmpty()) null else directPathForSafTree(treeUri),
            )
            return
        }
        if (method == "createDirectProbeFileExclusive") {
            result.success(createDirectProbeFileExclusive(call))
            return
        }
        if (method == "readDirectProbeFile") {
            result.success(readDirectProbeFile(call))
            return
        }
        if (method == "deleteDirectProbeFile") {
            result.success(deleteDirectProbeFile(call))
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
        if (call.method != "saveJsonl" && call.method != "saveJsonlToDownloadsDirectory") {
            result.notImplemented()
            return
        }
        val suggestedName = call.argument<String>("suggestedName")
        val bytes = call.argument<ByteArray>("bytes")
        if (suggestedName.isNullOrBlank() || bytes == null) {
            result.error("trace-export-arguments", "name and bytes are required", null)
            return
        }
        if (call.method == "saveJsonlToDownloadsDirectory") {
            val relativeDirectory = normalizeTraceExportRelativeDirectory(
                call.argument<String>("relativeDirectory"),
            )
            if (relativeDirectory == null) {
                result.error(
                    "trace-export-directory",
                    "relative Downloads directory is invalid",
                    null,
                )
                return
            }
            saveTraceToDownloadsDirectory(
                suggestedName,
                bytes,
                relativeDirectory,
                result,
            )
            return
        }
        if (pendingTraceResult != null) {
            result.error("trace-export-busy", "another trace export is active", null)
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
            Log.i(TAG, "trace-export-launch bytes=${bytes.size} mime=$mimeType")
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

    private fun normalizeTraceExportRelativeDirectory(value: String?): String? {
        val segments = value
            ?.replace('\\', '/')
            ?.split('/')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?: return null
        if (segments.isEmpty() || segments.any { it == "." || it == ".." || '\u0000' in it }) {
            return null
        }
        return segments.joinToString("/")
    }

    private fun saveTraceToDownloadsDirectory(
        suggestedName: String,
        bytes: ByteArray,
        relativeDirectory: String,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "trace-export-direct-unsupported",
                "direct Downloads export requires Android 10 or newer",
                null,
            )
            return
        }
        rhttpExecutor.execute {
            var uri: Uri? = null
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, suggestedName)
                    put(MediaStore.Downloads.MIME_TYPE, "application/x-ndjson")
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        "${Environment.DIRECTORY_DOWNLOADS}/$relativeDirectory",
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: throw IllegalStateException("unable to create Downloads trace document")
                contentResolver.openOutputStream(uri!!, "w").use { output ->
                    requireNotNull(output) { "unable to open Downloads trace document" }
                    output.write(bytes)
                    output.flush()
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri!!, values, null, null)
                val completedUri = uri.toString()
                Log.i(
                    TAG,
                    "trace-export-downloads-complete bytes=${bytes.size} " +
                        "directory=$relativeDirectory uri=$completedUri",
                )
                mainHandler.post { result.success(completedUri) }
            } catch (error: Throwable) {
                uri?.let { failedUri ->
                    runCatching { contentResolver.delete(failedUri, null, null) }
                }
                Log.e(TAG, "trace-export-downloads-failed", error)
                mainHandler.post {
                    result.error(
                        "trace-export-write-failed",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
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
        Log.i(
            TAG,
            "trace-export-result code=$resultCode hasUri=${data?.data != null} bytes=${bytes?.size ?: 0}",
        )
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
        val now = SystemClock.elapsedRealtime()
        synchronized(nativeStartupTimeline) {
            if (nativeStartupTimeline.size < 96) {
                nativeStartupTimeline.add(
                    mapOf(
                        "event" to event,
                        "elapsedRealtimeMs" to now,
                        "sinceProcessStartMs" to (now - processStartElapsedRealtimeMs),
                    ),
                )
            }
        }
        Log.i(TAG, "$event elapsedMs=$now")
    }

    override fun onDestroy() {
        startupLog("activity-onDestroy-start engineAttached=${configuredEngine != null}")
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
        pendingFirstFlutterUiDisplayedResult?.error(
            "startup-ui-wait-cancelled",
            "activity destroyed before first Flutter UI display",
            null,
        )
        pendingFirstFlutterUiDisplayedResult = null
        startupChannel?.setMethodCallHandler(null)
        startupChannel = null
        configuredEngine = null
        safExecutor.shutdownNow()
        localReadOpenExecutor.shutdownNow()
        safDescriptorExecutors.forEach { it.shutdownNow() }
        safDescriptors.values.forEach { descriptor ->
            try {
                descriptor.close()
            } catch (_: Throwable) {
                // Activity teardown owns final descriptor cleanup.
            }
        }
        safDescriptors.clear()
        rhttpExecutor.shutdownNow()
        super.onDestroy()
        startupLog("activity-onDestroy-complete")
    }
}
