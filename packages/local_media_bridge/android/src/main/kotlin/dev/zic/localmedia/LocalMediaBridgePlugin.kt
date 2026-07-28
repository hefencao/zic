package dev.zic.localmedia

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

class LocalMediaBridgePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val detached = AtomicBoolean(true)
    private var worker: ExecutorService? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private lateinit var channel: MethodChannel
    private lateinit var resolver: ContentResolver

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached.set(false)
        worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "zic-local-media").apply { isDaemon = true }
        }
        resolver = binding.applicationContext.contentResolver
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached.set(true)
        channel.setMethodCallHandler(null)
        finishPendingWithError("detached", "local media bridge detached")
        worker?.shutdownNow()
        worker = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun attachActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        finishPendingWithError("no_activity", "directory picker activity detached")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickImageDirectory" -> pickImageDirectory(result)
            "readDocument" -> readDocument(call, result)
            else -> result.notImplemented()
        }
    }

    private fun pickImageDirectory(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null || detached.get()) {
            result.error("no_activity", "no Android activity is available", null)
            return
        }
        synchronized(this) {
            if (pendingDirectoryResult != null) {
                result.error("picker_active", "an image directory picker is already active", null)
                return
            }
            pendingDirectoryResult = result
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        try {
            activity.startActivityForResult(intent, PICK_DIRECTORY_REQUEST)
        } catch (error: Throwable) {
            synchronized(this) { pendingDirectoryResult = null }
            result.error("picker_failed", error.message ?: error.toString(), null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_DIRECTORY_REQUEST) {
            return false
        }
        val result = synchronized(this) {
            pendingDirectoryResult.also { pendingDirectoryResult = null }
        } ?: return true
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return true
        }
        val treeUri = data.data!!
        val takeFlags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            resolver.takePersistableUriPermission(
                treeUri,
                if (takeFlags == 0) Intent.FLAG_GRANT_READ_URI_PERMISSION else takeFlags,
            )
        } catch (_: SecurityException) {
            // The transient grant from the picker remains valid for this session.
        }
        execute(result) {
            scanDirectory(treeUri).toMap()
        }
        return true
    }

    private fun readDocument(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("sourceUri")?.trim()
        if (raw.isNullOrEmpty()) {
            result.error("invalid_uri", "sourceUri is required", null)
            return
        }
        val uri = try {
            Uri.parse(raw)
        } catch (error: Throwable) {
            result.error("invalid_uri", error.message ?: error.toString(), null)
            return
        }
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("invalid_uri", "only content document URIs are supported", null)
            return
        }
        execute(result) {
            val mimeType = try {
                resolver.getType(uri)
            } catch (_: Throwable) {
                null
            }
            withDocumentInputStream(uri, mimeType) { input ->
                val bytes = readFully(input)
                if (bytes.size < MIN_MEDIA_BYTES) {
                    throw IOException("content resolver returned an empty/truncated stream for $uri")
                }
                bytes
            }
        }
    }

    private fun scanDirectory(treeUri: Uri): DirectoryScan {
        val rootDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocumentId)
        val rootName = queryDisplayName(rootUri).ifBlank { "本地图片" }
        val pending = ArrayDeque<PendingDirectory>()
        pending.add(PendingDirectory(rootDocumentId, ""))
        val visited = HashSet<String>()
        val documents = ArrayList<ImageDocument>()
        var scannedFiles = 0
        var unreadableFiles = 0
        var headerRecognizedFiles = 0
        var metadataRecognizedFiles = 0

        while (pending.isNotEmpty()) {
            val directory = pending.removeFirst()
            if (!visited.add(directory.documentId)) {
                continue
            }
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                directory.documentId,
            )
            resolver.query(childrenUri, DOCUMENT_PROJECTION, null, null, null).use { cursor ->
                if (cursor == null) {
                    throw IOException("content provider returned no cursor for $childrenUri")
                }
                val idColumn = cursor.requiredColumn(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = cursor.requiredColumn(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = cursor.requiredColumn(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val flagsColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
                while (cursor.moveToNext()) {
                    val documentId = cursor.getString(idColumn) ?: continue
                    val name = sanitizeDisplayName(cursor.getString(nameColumn))
                    val cursorMime = cursor.getString(mimeColumn) ?: ""
                    val relativeName = joinRelative(directory.relativePath, name)
                    if (cursorMime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        pending.add(PendingDirectory(documentId, relativeName))
                        continue
                    }
                    scannedFiles++
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        documentId,
                    )
                    val providerMime = cursorMime.ifBlank {
                        try {
                            resolver.getType(documentUri).orEmpty()
                        } catch (_: Throwable) {
                            ""
                        }
                    }
                    val virtualDocument = flagsColumn >= 0 &&
                        !cursor.isNull(flagsColumn) &&
                        cursor.getInt(flagsColumn) and
                        DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0
                    val header = try {
                        withDocumentInputStream(
                            documentUri,
                            providerMime,
                            preferTyped = virtualDocument,
                        ) { input ->
                            val bytes = readPrefix(input, HEADER_PROBE_BYTES)
                            if (bytes.size < MIN_MEDIA_BYTES) {
                                throw IOException("content resolver returned an empty/truncated probe")
                            }
                            bytes
                        }
                    } catch (_: IOException) {
                        unreadableFiles++
                        null
                    } catch (_: SecurityException) {
                        unreadableFiles++
                        null
                    }
                    val resolution = resolveDirectoryCandidate(
                        header,
                        providerMime,
                        name,
                    )
                    if (resolution != null) {
                        if (resolution.origin == "header") {
                            headerRecognizedFiles++
                        } else {
                            metadataRecognizedFiles++
                        }
                        val size = if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                            cursor.getLong(sizeColumn).takeIf { it >= 0L }
                        } else {
                            null
                        }
                        documents.add(
                            ImageDocument(
                                sourceUri = documentUri.toString(),
                                displayName = relativeName,
                                format = resolution.format,
                                recognition = resolution.origin,
                                byteLength = size,
                            ),
                        )
                    }
                }
            }
        }
        documents.sortWith(NaturalDocumentComparator)
        return DirectoryScan(
            treeUri = treeUri.toString(),
            displayName = rootName,
            documents = documents,
            scannedFiles = scannedFiles,
            unreadableFiles = unreadableFiles,
            headerRecognizedFiles = headerRecognizedFiles,
            metadataRecognizedFiles = metadataRecognizedFiles,
        )
    }


    private fun <T> withDocumentInputStream(
        uri: Uri,
        mimeType: String?,
        preferTyped: Boolean = false,
        operation: (InputStream) -> T,
    ): T {
        val failures = ArrayList<Throwable>()

        fun ordinary(): T? {
            return try {
                resolver.openInputStream(uri)?.use(operation)
            } catch (error: Throwable) {
                failures.add(error)
                null
            }
        }

        fun asset(): T? {
            return try {
                resolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                    descriptor.createInputStream().use(operation)
                }
            } catch (error: Throwable) {
                failures.add(error)
                null
            }
        }

        fun typed(): T? {
            val requestedType = mimeType
                ?.takeIf { it.startsWith("image/") }
                ?: "image/*"
            return try {
                resolver.openTypedAssetFileDescriptor(
                    uri,
                    requestedType,
                    null,
                )?.use { descriptor ->
                    descriptor.createInputStream().use(operation)
                }
            } catch (error: Throwable) {
                failures.add(error)
                null
            }
        }

        val value = if (preferTyped) {
            typed() ?: ordinary() ?: asset()
        } else {
            ordinary() ?: asset() ?: typed()
        }
        if (value != null) {
            return value
        }
        val failure = IOException("content resolver returned no readable stream for $uri")
        failures.forEach(failure::addSuppressed)
        throw failure
    }

    private fun queryDisplayName(documentUri: Uri): String {
        return try {
            resolver.query(
                documentUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            ).use { cursor ->
                if (cursor != null && cursor.moveToFirst()) {
                    cursor.getString(0) ?: ""
                } else {
                    ""
                }
            }
        } catch (_: Throwable) {
            ""
        }
    }

    private fun execute(result: MethodChannel.Result, operation: () -> Any?) {
        val lane = worker
        if (lane == null || detached.get()) {
            result.error("detached", "local media bridge is detached", null)
            return
        }
        try {
            lane.execute {
                try {
                    val value = operation()
                    mainHandler.post {
                        if (detached.get()) {
                            result.error("detached", "local media bridge detached", null)
                        } else {
                            result.success(value)
                        }
                    }
                } catch (error: Throwable) {
                    mainHandler.post {
                        result.error("media_io_failed", error.message ?: error.toString(), null)
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("detached", "local media worker is unavailable", null)
        }
    }

    private fun finishPendingWithError(code: String, message: String) {
        val result = synchronized(this) {
            pendingDirectoryResult.also { pendingDirectoryResult = null }
        }
        result?.error(code, message, null)
    }

    private data class PendingDirectory(
        val documentId: String,
        val relativePath: String,
    )

    private data class ImageDocument(
        val sourceUri: String,
        val displayName: String,
        val format: String,
        val recognition: String,
        val byteLength: Long?,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "sourceUri" to sourceUri,
            "displayName" to displayName,
            "format" to format,
            "recognition" to recognition,
            "byteLength" to byteLength,
        )
    }

    private data class DirectoryScan(
        val treeUri: String,
        val displayName: String,
        val documents: List<ImageDocument>,
        val scannedFiles: Int,
        val unreadableFiles: Int,
        val headerRecognizedFiles: Int,
        val metadataRecognizedFiles: Int,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "protocolVersion" to PROTOCOL_VERSION,
            "treeUri" to treeUri,
            "displayName" to displayName,
            "documents" to documents.map(ImageDocument::toMap),
            "scannedFiles" to scannedFiles,
            "unreadableFiles" to unreadableFiles,
            "headerRecognizedFiles" to headerRecognizedFiles,
            "metadataRecognizedFiles" to metadataRecognizedFiles,
        )
    }

    private object NaturalDocumentComparator : Comparator<ImageDocument> {
        override fun compare(left: ImageDocument, right: ImageDocument): Int =
            naturalCompare(left.displayName, right.displayName)
    }

    companion object {
        private const val CHANNEL_NAME = "dev.zic/local_media"
        private const val PROTOCOL_VERSION = 2
        private const val PICK_DIRECTORY_REQUEST = 0x5A31
        private const val HEADER_PROBE_BYTES = 64
        private const val MIN_MEDIA_BYTES = 4
        internal const val READ_BUFFER_BYTES = 64 * 1024
        private val DOCUMENT_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
    }
}

private fun Cursor.requiredColumn(name: String): Int {
    val index = getColumnIndex(name)
    if (index < 0) {
        throw IOException("content provider omitted required column $name")
    }
    return index
}

private fun sanitizeDisplayName(value: String?): String {
    val normalized = value?.trim().orEmpty().replace('/', '／').replace('\\', '＼')
    return if (normalized.isEmpty()) "未命名文件" else normalized
}

private fun joinRelative(parent: String, child: String): String =
    if (parent.isEmpty()) child else "$parent/$child"

private fun readPrefix(input: InputStream, limit: Int): ByteArray {
    val output = ByteArrayOutputStream(limit)
    val buffer = ByteArray(minOf(4096, limit))
    while (output.size() < limit) {
        val count = input.read(buffer, 0, minOf(buffer.size, limit - output.size()))
        if (count < 0) {
            break
        }
        if (count == 0) {
            continue
        }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private fun readFully(input: InputStream): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(LocalMediaBridgePlugin.READ_BUFFER_BYTES)
    while (true) {
        val count = input.read(buffer)
        if (count < 0) {
            break
        }
        if (count == 0) {
            continue
        }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
