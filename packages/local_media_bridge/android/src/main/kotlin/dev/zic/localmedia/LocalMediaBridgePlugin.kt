package dev.zic.localmedia

import android.app.Activity
import android.content.res.AssetFileDescriptor
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import android.util.Size
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
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
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
    private val documentHandles = ConcurrentHashMap<String, DocumentReadHandle>()
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
        closeAllDocuments()
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
            "scanImageDirectory" -> scanImageDirectory(call, result)
            "readDocumentThumbnail" -> readDocumentThumbnail(call, result)
            "readDocument" -> readDocument(call, result)
            "openDocument" -> openDocument(call, result)
            "readDocumentChunk" -> readDocumentChunk(call, result)
            "closeDocument" -> closeDocument(call, result)
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


    private fun scanImageDirectory(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("treeUri")?.trim()
        if (raw.isNullOrEmpty()) {
            result.error("invalid_uri", "treeUri is required", null)
            return
        }
        val treeUri = try {
            Uri.parse(raw)
        } catch (error: Throwable) {
            result.error("invalid_uri", error.message ?: error.toString(), null)
            return
        }
        if (treeUri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("invalid_uri", "a content document-tree URI is required", null)
            return
        }
        execute(result) {
            scanDirectory(treeUri).toMap()
        }
    }

    private fun openDocument(call: MethodCall, result: MethodChannel.Result) {
        val uri = requireContentUri(call, result) ?: return
        val requestedStart = call.argument<Number>("start")?.toLong() ?: 0L
        val requestedEnd = call.argument<Number>("endExclusive")?.toLong()
        val expectedRevision = call.argument<String>("expectedRevision")
        if (requestedStart < 0L || (requestedEnd != null && requestedEnd < requestedStart)) {
            result.error("invalid_range", "document byte range is invalid", null)
            return
        }
        execute(result) {
            val metadata = queryDocumentReadMetadata(uri)
            val revision = documentRevision(uri, metadata)
            val rangeRequested = requestedStart > 0L || requestedEnd != null
            val canServeRange = rangeRequested &&
                (expectedRevision == null || expectedRevision == revision)
            val rangeStart = if (canServeRange) requestedStart else 0L
            val descriptor = openDocumentDescriptor(uri, metadata.mimeType)
            val totalLength = metadata.byteLength
                ?: descriptor.length.takeIf { it >= 0L }
            val boundedEnd = if (!canServeRange) {
                totalLength
            } else {
                when {
                    requestedEnd == null -> totalLength
                    totalLength == null -> requestedEnd
                    else -> minOf(requestedEnd, totalLength)
                }
            }
            val remaining = boundedEnd?.let { (it - rangeStart).coerceAtLeast(0L) }
            val handleId = UUID.randomUUID().toString()
            documentHandles[handleId] = DocumentReadHandle(
                descriptor = descriptor,
                remaining = remaining,
                openInput = {
                    val input = descriptor.createInputStream()
                    try {
                        skipFully(input, rangeStart)
                        input
                    } catch (error: Throwable) {
                        input.close()
                        throw error
                    }
                },
            )
            if (detached.get()) {
                documentHandles.remove(handleId)?.close()
                throw IOException("local media bridge detached while opening $uri")
            }
            val directDescriptor = descriptor.takeIf { isSeekableDescriptor(it) }
            val directStart = directDescriptor?.let { it.startOffset + rangeStart }
            val directEndExclusive = if (directStart == null || remaining == null) {
                null
            } else {
                directStart + remaining
            }
            mapOf(
                "handleId" to handleId,
                "rangeStart" to rangeStart,
                "totalLength" to totalLength,
                "revision" to revision,
                "rangeSupported" to true,
                "partial" to canServeRange,
                "directPath" to directDescriptor?.let {
                    "/proc/self/fd/${it.parcelFileDescriptor.fd}"
                },
                "directStart" to directStart,
                "directEndExclusive" to directEndExclusive,
            )
        }
    }

    private fun readDocumentChunk(call: MethodCall, result: MethodChannel.Result) {
        val handleId = call.argument<String>("handleId")?.trim()
        val requested = call.argument<Number>("maxBytes")?.toInt()
            ?: DOCUMENT_CHUNK_BYTES
        if (handleId.isNullOrEmpty() || requested <= 0) {
            result.error("invalid_handle", "handleId and maxBytes are required", null)
            return
        }
        execute(result) {
            val handle = documentHandles[handleId]
                ?: throw IOException("local document handle is closed: $handleId")
            val chunk = handle.read(minOf(requested, DOCUMENT_CHUNK_BYTES))
            if (chunk.isEmpty()) {
                documentHandles.remove(handleId)?.close()
            }
            chunk
        }
    }

    private fun closeDocument(call: MethodCall, result: MethodChannel.Result) {
        val handleId = call.argument<String>("handleId")?.trim()
        if (handleId.isNullOrEmpty()) {
            result.error("invalid_handle", "handleId is required", null)
            return
        }
        execute(result) {
            documentHandles.remove(handleId)?.close()
            null
        }
    }

    private fun requireContentUri(
        call: MethodCall,
        result: MethodChannel.Result,
    ): Uri? {
        val raw = call.argument<String>("sourceUri")?.trim()
        if (raw.isNullOrEmpty()) {
            result.error("invalid_uri", "sourceUri is required", null)
            return null
        }
        val uri = try {
            Uri.parse(raw)
        } catch (error: Throwable) {
            result.error("invalid_uri", error.message ?: error.toString(), null)
            return null
        }
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("invalid_uri", "only content document URIs are supported", null)
            return null
        }
        return uri
    }

    private fun queryDocumentReadMetadata(uri: Uri): DocumentReadMetadata {
        var byteLength: Long? = null
        var lastModified: Long? = null
        var mimeType: String? = null
        try {
            resolver.query(
                uri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                ),
                null,
                null,
                null,
            ).use { cursor ->
                if (cursor != null && cursor.moveToFirst()) {
                    val size = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                    val modified = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    )
                    val mime = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    if (size >= 0 && !cursor.isNull(size)) {
                        byteLength = cursor.getLong(size).takeIf { it >= 0L }
                    }
                    if (modified >= 0 && !cursor.isNull(modified)) {
                        lastModified = cursor.getLong(modified).takeIf { it >= 0L }
                    }
                    if (mime >= 0 && !cursor.isNull(mime)) {
                        mimeType = cursor.getString(mime)
                    }
                }
            }
        } catch (_: Throwable) {
            // Metadata is advisory; descriptor streaming remains authoritative.
        }
        if (mimeType.isNullOrBlank()) {
            mimeType = runCatching { resolver.getType(uri) }.getOrNull()
        }
        return DocumentReadMetadata(byteLength, lastModified, mimeType)
    }

    private fun openDocumentDescriptor(
        uri: Uri,
        mimeType: String?,
    ): AssetFileDescriptor {
        val failures = ArrayList<Throwable>()
        try {
            resolver.openAssetFileDescriptor(uri, "r")?.let { return it }
        } catch (error: Throwable) {
            failures.add(error)
        }
        try {
            resolver.openTypedAssetFileDescriptor(
                uri,
                mimeType?.takeIf { it.startsWith("image/") } ?: "image/*",
                null,
            )?.let { return it }
        } catch (error: Throwable) {
            failures.add(error)
        }
        val failure = IOException("content resolver returned no file descriptor for $uri")
        failures.forEach(failure::addSuppressed)
        throw failure
    }


    private fun isSeekableDescriptor(descriptor: AssetFileDescriptor): Boolean =
        try {
            val fileDescriptor = descriptor.parcelFileDescriptor.fileDescriptor
            val position = Os.lseek(fileDescriptor, 0L, OsConstants.SEEK_CUR)
            Os.lseek(fileDescriptor, position, OsConstants.SEEK_SET)
            true
        } catch (_: Throwable) {
            false
        }

    private fun documentRevision(uri: Uri, metadata: DocumentReadMetadata): String =
        "${metadata.byteLength ?: -1}:${metadata.lastModified ?: -1}:${uri}"

    private fun closeAllDocuments() {
        val handles = documentHandles.values.toList()
        documentHandles.clear()
        handles.forEach { handle -> runCatching(handle::close) }
    }

    private fun readDocumentThumbnail(call: MethodCall, result: MethodChannel.Result) {
        val uri = requireContentUri(call, result) ?: return
        val maxWidth = call.argument<Number>("maxWidth")?.toInt() ?: 512
        val maxHeight = call.argument<Number>("maxHeight")?.toInt() ?: 768
        if (maxWidth <= 0 || maxHeight <= 0 || maxWidth > 2048 || maxHeight > 2048) {
            result.error("invalid_size", "thumbnail bounds are invalid", null)
            return
        }
        execute(result) {
            val bitmap = loadDocumentThumbnail(uri, maxWidth, maxHeight)
                ?: return@execute null
            try {
                val output = ByteArrayOutputStream()
                val format = if (bitmap.hasAlpha()) {
                    Bitmap.CompressFormat.PNG
                } else {
                    Bitmap.CompressFormat.JPEG
                }
                val quality = if (format == Bitmap.CompressFormat.JPEG) 88 else 100
                if (!bitmap.compress(format, quality, output)) {
                    return@execute null
                }
                output.toByteArray().takeIf { it.size >= MIN_MEDIA_BYTES }
            } finally {
                bitmap.recycle()
            }
        }
    }

    private fun loadDocumentThumbnail(
        uri: Uri,
        maxWidth: Int,
        maxHeight: Int,
    ): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                return resolver.loadThumbnail(uri, Size(maxWidth, maxHeight), null)
            } catch (_: Throwable) {
                // Some DocumentsProviders do not implement thumbnail loading.
                // Fall back to a sampled descriptor decode without crossing the
                // original encoded body through the Flutter MethodChannel.
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            BitmapFactory.decodeFileDescriptor(descriptor.fileDescriptor, null, bounds)
        } ?: return null
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sampleSize = 1
        while (bounds.outWidth / (sampleSize * 2) >= maxWidth &&
            bounds.outHeight / (sampleSize * 2) >= maxHeight
        ) {
            sampleSize *= 2
        }
        val decoded = resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            BitmapFactory.decodeFileDescriptor(
                descriptor.fileDescriptor,
                null,
                BitmapFactory.Options().apply { inSampleSize = sampleSize },
            )
        } ?: return null
        val scale = minOf(
            1.0f,
            maxWidth.toFloat() / decoded.width.toFloat(),
            maxHeight.toFloat() / decoded.height.toFloat(),
        )
        if (scale >= 1.0f) return decoded
        val scaledWidth = maxOf(1, (decoded.width * scale).toInt())
        val scaledHeight = maxOf(1, (decoded.height * scale).toInt())
        val scaled = Bitmap.createScaledBitmap(decoded, scaledWidth, scaledHeight, true)
        if (scaled !== decoded) decoded.recycle()
        return scaled
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

    private data class DocumentReadMetadata(
        val byteLength: Long?,
        val lastModified: Long?,
        val mimeType: String?,
    )

    private class DocumentReadHandle(
        private val descriptor: AssetFileDescriptor,
        private var remaining: Long?,
        private val openInput: () -> InputStream,
    ) {
        private var input: InputStream? = null

        fun read(maxBytes: Int): ByteArray {
            val available = remaining
            if (available != null && available <= 0L) return ByteArray(0)
            val size = if (available == null) {
                maxBytes
            } else {
                minOf(maxBytes.toLong(), available).toInt()
            }
            val source = input ?: openInput().also { input = it }
            val buffer = ByteArray(size)
            var count = 0
            while (count < size) {
                val read = source.read(buffer, count, size - count)
                if (read < 0) break
                if (read == 0) continue
                count += read
            }
            if (count <= 0) return ByteArray(0)
            remaining = remaining?.minus(count.toLong())
            return if (count == buffer.size) buffer else buffer.copyOf(count)
        }

        fun close() {
            try {
                input?.close()
            } finally {
                descriptor.close()
            }
        }
    }

    companion object {
        private const val CHANNEL_NAME = "dev.zic/local_media"
        private const val PROTOCOL_VERSION = 5
        private const val DOCUMENT_CHUNK_BYTES = 1024 * 1024
        private const val PICK_DIRECTORY_REQUEST = 0x5A31
        private const val HEADER_PROBE_BYTES = 64
        private const val MIN_MEDIA_BYTES = 4
        internal const val READ_BUFFER_BYTES = 1024 * 1024
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

private fun skipFully(input: InputStream, byteCount: Long) {
    var remaining = byteCount
    while (remaining > 0L) {
        val skipped = input.skip(remaining)
        if (skipped > 0L) {
            remaining -= skipped
            continue
        }
        if (input.read() < 0) {
            throw IOException("content resolver stream ended before requested range")
        }
        remaining--
    }
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
