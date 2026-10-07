package dev.zic.pluginhost

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.io.Closeable
import java.io.ByteArrayOutputStream
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

private const val ISOLATED_MODIFY_IMAGE_ARGUMENT = "__zicIsolatedModifyImage"
private const val MAX_ISOLATED_MODIFY_IMAGE_SCRIPT_BYTES = 64 * 1024

/**
 * Conservative qualification for the source-provided `modifyImage` string.
 *
 * The isolated plane intentionally accepts only scripts that can run from the
 * ordinary ECMAScript realm plus the Venera `Image` primitive. Missing source
 * globals are still detected dynamically as ReferenceError and fall back to
 * the canonical source WebView. These lexical exclusions close the cases that
 * could otherwise observe a missing global without throwing (`typeof`,
 * try/catch, global object access) or escape into browser/network state.
 */
internal fun isIsolatedVeneraModifyImageCandidate(script: String): Boolean {
    val trimmed = script.trim()
    if (trimmed.isEmpty() ||
        trimmed.toByteArray(Charsets.UTF_8).size > MAX_ISOLATED_MODIFY_IMAGE_SCRIPT_BYTES ||
        !Regex("\\bmodifyImage\\b").containsMatchIn(trimmed)
    ) {
        return false
    }
    val forbidden = listOf(
        "Network",
        "Convert",
        "APP",
        "ComicSource",
        "sendMessage",
        "ZicNative",
        "ZicTransform",
        "fetch",
        "XMLHttpRequest",
        "WebSocket",
        "document",
        "window",
        "globalThis",
        "self",
        "location",
        "navigator",
        "localStorage",
        "sessionStorage",
        "indexedDB",
        "eval",
        "Function",
        "import",
        "require",
        "typeof",
        "try",
        "catch",
        "this",
    )
    return forbidden.none { token ->
        Regex("(^|[^A-Za-z0-9_$])${Regex.escape(token)}([^A-Za-z0-9_$]|$)")
            .containsMatchIn(trimmed)
    }
}

internal fun isolatedModifyImageScript(request: Map<String, Any?>): String? {
    if (request["operation"] != "transformResource") return null
    val arguments = request["arguments"] as? Map<*, *> ?: return null
    return (arguments[ISOLATED_MODIFY_IMAGE_ARGUMENT] as? String)
        ?.takeIf(::isIsolatedVeneraModifyImageCandidate)
}

/**
 * Small pool for source-independent Venera image transforms.
 *
 * The canonical source WebView remains strictly single-invocation. Only
 * scripts already proven isolated-compatible enter this pool. Each worker owns
 * an independent WebView and Bitmap namespace, so one request's disposeAll
 * cannot invalidate another request's image handles.
 */
internal class VeneraImageTransformRuntime(
    context: Context,
    private val driverId: String,
    maxResponseBytes: Int,
    executor: ExecutorService,
) : Closeable {
    private val workers = List(MAX_CONCURRENT_TRANSFORMS) { index ->
        VeneraImageTransformWorker(
            context = context,
            driverId = "$driverId:$index",
            maxResponseBytes = maxResponseBytes,
            executor = executor,
        )
    }
    private val assignmentLock = Any()
    private val assignments =
        ConcurrentHashMap<String, VeneraImageTransformWorker>()
    private val busyWorkers =
        ConcurrentHashMap.newKeySet<VeneraImageTransformWorker>()
    private val prewarmCount = AtomicInteger(0)
    private val closed = AtomicBoolean(false)
    private val closeCompletion = CompletableFuture<Unit>()

    fun prewarm() {
        if (closed.get()) return
        val index = prewarmCount.getAndIncrement().coerceAtMost(workers.lastIndex)
        workers[index].prewarm()
    }

    fun invoke(
        requestId: String,
        script: String,
        bytes: ByteArray,
        result: NativeDriverResult,
    ) = invoke(requestId, script, bytes, result, null, {})

    fun invoke(
        requestId: String,
        script: String,
        bytes: ByteArray,
        result: NativeDriverResult,
        encodeBody: ((Bitmap, () -> Unit) -> RuntimeServiceBodyReference)?,
        discardBody: (RuntimeServiceBodyReference) -> Unit,
    ) {
        if (closed.get()) {
            result.error("runtime-closing", "Venera image transform runtime is closing")
            return
        }
        val worker = synchronized(assignmentLock) {
            if (closed.get()) return@synchronized null
            workers.firstOrNull { candidate ->
                !busyWorkers.contains(candidate)
            }?.also {
                busyWorkers.add(it)
                assignments[requestId] = it
            }
        }
        if (worker == null) {
            result.error(
                "venera-isolated-transform-unavailable",
                "Venera isolated transform worker pool is saturated",
            )
            return
        }
        worker.invoke(
            requestId = requestId,
            script = script,
            bytes = bytes,
            encodeBody = encodeBody,
            discardBody = discardBody,
            result = object : NativeDriverResult {
                override fun success(value: Any) {
                    release(requestId, worker)
                    result.success(value)
                }

                override fun error(
                    code: String,
                    message: String,
                    retryable: Boolean,
                    details: Map<String, Any?>,
                ) {
                    release(requestId, worker)
                    result.error(code, message, retryable, details)
                }
            },
        )
    }

    fun cancel(requestId: String) {
        assignments[requestId]?.cancel(requestId)
    }

    override fun close() {
        closeWhenDrained()
    }

    fun closeWhenDrained(): CompletableFuture<Unit> {
        if (!closed.compareAndSet(false, true)) return closeCompletion
        CompletableFuture.allOf(*workers.map { it.closeWhenDrained() }.toTypedArray())
            .whenComplete { _, failure ->
                synchronized(assignmentLock) {
                    assignments.clear()
                    busyWorkers.clear()
                }
                if (failure == null) {
                    closeCompletion.complete(Unit)
                } else {
                    closeCompletion.completeExceptionally(failure)
                }
            }
        return closeCompletion
    }

    private fun release(
        requestId: String,
        worker: VeneraImageTransformWorker,
    ) {
        synchronized(assignmentLock) {
            assignments.remove(requestId, worker)
            busyWorkers.remove(worker)
        }
    }

    companion object {
        const val MAX_CONCURRENT_TRANSFORMS = 2
    }
}

/**
 * UI-less image-only JavaScript context for source-provided Venera
 * `modifyImage` programs.
 *
 * It deliberately does not load the source script and exposes no Network,
 * Cookie, settings or source-data bridge. The canonical source WebView remains
 * physically single-invocation; this context only lets CPU-heavy bitmap
 * transforms overlap request-plan resolution without changing source state.
 */
private class VeneraImageTransformWorker(
    context: Context,
    private val driverId: String,
    private val maxResponseBytes: Int,
    executor: ExecutorService,
) : Closeable {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private data class PendingTransform(
        val result: NativeDriverResult,
        val encodeBody: ((Bitmap, () -> Unit) -> RuntimeServiceBodyReference)?,
        val discardBody: (RuntimeServiceBodyReference) -> Unit,
    )

    private val pending = ConcurrentHashMap<String, PendingTransform>()
    private val inputs = ConcurrentHashMap<String, ByteArray>()
    private val completions = ConcurrentHashMap<String, Completion>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val started = ConcurrentHashMap.newKeySet<String>()
    private val startedAtNanos = ConcurrentHashMap<String, Long>()
    private val closed = AtomicBoolean(false)
    private val submissions = NativeRuntimeWorkDrain()
    private val closeCompletion = CompletableFuture<Unit>()
    private val bridge = TransformBridge(
        maxResponseBytes = maxResponseBytes,
        executor = executor,
        takeInput = { requestId -> inputs.remove(requestId) },
        encodeBody = { requestId, bitmap ->
            val task = pending[requestId] ?: error("Venera transform request has retired")
            task.encodeBody?.invoke(bitmap) {
                if (closed.get() || cancelled.contains(requestId)) throw CancellationException()
            }
        },
        onSuccess = { requestId, value ->
            val task = pending[requestId]
            val completion = Completion.Success(value) {
                if (value is RuntimeServiceBodyReference) task?.discardBody?.invoke(value)
            }
            if (closed.get()) completion.discard()
            else discardCompletion(completions.put(requestId, completion))
        },
        onFailure = { requestId, code, message ->
            discardCompletion(completions.put(requestId, Completion.Failure(code, message)))
        },
        onFinished = ::finish,
        onEncoded = { requestId ->
            mainHandler.post {
                if (!closed.get()) webView?.evaluateJavascript(
                    "__zicImageTransformEncoded(${JSONObject.quote(requestId)});",
                    null,
                )
            }
        },
    )
    private var webView: WebView? = null
    private var ready = false
    private var initializationFailed = false

    fun prewarm() {
        if (closed.get() || ready || initializationFailed || webView != null) return
        mainHandler.post { ensureCreated() }
    }

    fun invoke(
        requestId: String,
        script: String,
        bytes: ByteArray,
        result: NativeDriverResult,
        encodeBody: ((Bitmap, () -> Unit) -> RuntimeServiceBodyReference)?,
        discardBody: (RuntimeServiceBodyReference) -> Unit,
    ) {
        val work = submissions.begin()
        if (work == null) {
            result.error("runtime-closing", "Venera image transform runtime is closing")
            return
        }
        try {
            invokeAccepted(requestId, script, bytes, PendingTransform(result, encodeBody, discardBody))
        } finally {
            work.finish()
        }
    }

    private fun invokeAccepted(
        requestId: String,
        script: String,
        bytes: ByteArray,
        task: PendingTransform,
    ) {
        val result = task.result
        if (closed.get()) {
            result.error("runtime-closing", "Venera image transform runtime is closing")
            return
        }
        if (!isIsolatedVeneraModifyImageCandidate(script)) {
            result.error(
                "venera-isolated-transform-incompatible",
                "Venera modifyImage requires the canonical source context",
            )
            return
        }
        if (bytes.size > maxResponseBytes) {
            result.error(
                "venera-operation-failed",
                "Venera isolated transform input exceeds runtime limit",
            )
            return
        }
        if (pending.putIfAbsent(requestId, task) != null) {
            result.error(
                "venera-operation-failed",
                "Venera isolated transform request identity is already active",
            )
            return
        }
        inputs[requestId] = bytes
        startedAtNanos[requestId] = SystemClock.elapsedRealtimeNanos()
        Log.i(
            LOG_TAG,
            "isolated-transform-start driver=$driverId request=$requestId inputBytes=${bytes.size}",
        )
        mainHandler.post {
            if (closed.get()) return@post
            if (initializationFailed) {
                finishUnavailable(requestId, "Venera image transform runtime is unavailable")
                return@post
            }
            ensureCreated()
            if (ready) {
                start(requestId, script)
            } else {
                queuedScripts[requestId] = script
            }
        }
    }

    fun cancel(requestId: String) {
        if (!pending.containsKey(requestId)) return
        cancelled.add(requestId)
        if (!started.contains(requestId)) {
            queuedScripts.remove(requestId)
            inputs.remove(requestId)
            discardCompletion(completions.remove(requestId))
            val result = pending.remove(requestId)?.result ?: return
            cancelled.remove(requestId)
            startedAtNanos.remove(requestId)
            result.error("runtime-request-cancelled", "Venera request was cancelled")
        }
    }

    override fun close() {
        closeWhenDrained()
    }

    fun closeWhenDrained(): CompletableFuture<Unit> {
        if (!closed.compareAndSet(false, true)) return closeCompletion
        CompletableFuture.allOf(submissions.close(), bridge.closeWhenDrained())
            .whenComplete { _, failure ->
                mainHandler.post {
                    runCatching {
                        webView?.let { view ->
                            view.removeJavascriptInterface(BRIDGE_NAME)
                            view.stopLoading()
                            view.loadUrl("about:blank")
                            view.clearHistory()
                            view.removeAllViews()
                            view.destroy()
                        }
                        webView = null
                        ready = false
                        pending.keys.toList().forEach { requestId ->
                            pending.remove(requestId)?.result?.error(
                                "runtime-closing",
                                "Venera image transform runtime is closing",
                            )
                        }
                        queuedScripts.clear()
                        inputs.clear()
                        completions.values.forEach(::discardCompletion)
                        completions.clear()
                        started.clear()
                        cancelled.clear()
                        startedAtNanos.clear()
                        if (failure != null) throw failure
                    }.fold(
                        onSuccess = { closeCompletion.complete(Unit) },
                        onFailure = { closeCompletion.completeExceptionally(it) },
                    )
                }
            }
        return closeCompletion
    }

    private val queuedScripts = ConcurrentHashMap<String, String>()

    @SuppressLint("SetJavaScriptEnabled")
    private fun ensureCreated() {
        if (closed.get() || ready || initializationFailed || webView != null) return
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { ensureCreated() }
            return
        }
        val view = runCatching { WebView(appContext) }.getOrElse {
            initializationFailed = true
            failQueuedInitialization()
            return
        }
        webView = view
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            databaseEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
        }
        view.addJavascriptInterface(bridge, BRIDGE_NAME)
        view.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                if (closed.get() || ready) return
                view.evaluateJavascript(TRANSFORM_BOOTSTRAP) {
                    if (closed.get() || ready) return@evaluateJavascript
                    ready = true
                    val queued = queuedScripts.toMap()
                    queuedScripts.clear()
                    queued.forEach { (requestId, script) -> start(requestId, script) }
                }
            }
        }
        view.loadDataWithBaseURL(
            "https://zic.transform.invalid/",
            "<html><head></head><body></body></html>",
            "text/html",
            "utf-8",
            null,
        )
        mainHandler.postDelayed(
            {
                if (!ready && !closed.get()) {
                    initializationFailed = true
                    failQueuedInitialization()
                }
            },
            INITIALIZATION_TIMEOUT_MILLIS,
        )
    }

    private fun start(requestId: String, script: String) {
        if (!pending.containsKey(requestId)) return
        if (cancelled.contains(requestId)) {
            cancel(requestId)
            return
        }
        val view = webView
        if (!ready || view == null) {
            queuedScripts[requestId] = script
            return
        }
        started.add(requestId)
        view.evaluateJavascript(
            "__zicRunImageTransform(${JSONObject.quote(requestId)}," +
                "${JSONObject.quote(script)});",
            null,
        )
    }

    private fun finish(requestId: String) {
        if (closed.get()) return
        inputs.remove(requestId)
        started.remove(requestId)
        val result = pending.remove(requestId)?.result ?: run {
            discardCompletion(completions.remove(requestId))
            cancelled.remove(requestId)
            startedAtNanos.remove(requestId)
            return
        }
        val elapsedMicros = startedAtNanos.remove(requestId)?.let { startedAt ->
            (SystemClock.elapsedRealtimeNanos() - startedAt) / 1_000L
        }
        if (cancelled.remove(requestId)) {
            discardCompletion(completions.remove(requestId))
            result.error("runtime-request-cancelled", "Venera request was cancelled")
            return
        }
        when (val completion = completions.remove(requestId)) {
            is Completion.Success -> {
                Log.i(
                    LOG_TAG,
                    "isolated-transform-finish driver=$driverId request=$requestId " +
                        "elapsedMicros=${elapsedMicros ?: -1} outputBytes=${completion.byteLength}",
                )
                result.success(completion.value)
            }
            is Completion.Failure -> result.error(
                completion.code,
                completion.message.take(300),
            )
            null -> result.error(
                "venera-isolated-transform-unavailable",
                "Venera isolated transform finished without a result",
            )
        }
    }

    private fun finishUnavailable(requestId: String, message: String) {
        queuedScripts.remove(requestId)
        inputs.remove(requestId)
        discardCompletion(completions.remove(requestId))
        started.remove(requestId)
        cancelled.remove(requestId)
        startedAtNanos.remove(requestId)
        pending.remove(requestId)?.result?.error(
            "venera-isolated-transform-unavailable",
            message,
        )
    }

    private fun failQueuedInitialization() {
        val requestIds = queuedScripts.keys.toList()
        queuedScripts.clear()
        requestIds.forEach { requestId ->
            finishUnavailable(requestId, "Venera image transform runtime failed to initialize")
        }
    }

    private fun discardCompletion(completion: Completion?) {
        if (completion is Completion.Success) completion.discard()
    }

    private sealed interface Completion {
        data class Success(val value: Any, val discard: () -> Unit) : Completion {
            val byteLength: Long get() = when (value) {
                is ByteArray -> value.size.toLong()
                is RuntimeServiceBodyReference -> value.byteLength
                else -> error("invalid Venera transform output")
            }
        }
        data class Failure(val code: String, val message: String) : Completion
    }

    private class TransformBridge(
        private val maxResponseBytes: Int,
        private val executor: ExecutorService,
        private val takeInput: (String) -> ByteArray?,
        private val encodeBody: (String, Bitmap) -> RuntimeServiceBodyReference?,
        private val onSuccess: (String, Any) -> Unit,
        private val onFailure: (String, String, String) -> Unit,
        private val onFinished: (String) -> Unit,
        private val onEncoded: (String) -> Unit,
    ) : Closeable {
        private val images = ConcurrentHashMap<Int, Bitmap>()
        private val nextImageKey = AtomicInteger(1)
        private val closed = AtomicBoolean(false)
        private val nativeWork = NativeRuntimeWorkDrain()
        private val closeCompletion = CompletableFuture<Unit>()

        @JavascriptInterface
        fun request(raw: String): String {
            val work = nativeWork.begin()
            if (work == null) return JSONObject().put("ok", false)
                .put("message", "Venera isolated transform bridge is closed").toString()
            return try {
                requestAccepted(raw)
            } finally {
                work.finish()
            }
        }

        private fun requestAccepted(raw: String): String {
            val response = runCatching {
                check(!closed.get()) { "Venera isolated transform bridge is closed" }
                val message = JSONObject(raw)
                val value = image(message)
                JSONObject().put("ok", true).put("value", value).toString()
            }.getOrElse { error ->
                JSONObject()
                    .put("ok", false)
                    .put("message", error.message ?: "Venera image operation failed")
                    .toString()
            }
            return response
        }

        @JavascriptInterface
        fun complete(requestId: String, imageKey: Int) {
            val work = nativeWork.begin() ?: return
            try {
                // WebViews can share one JavaBridge thread. Only the admitted
                // output encode borrows the host executor; JS keeps the worker
                // and Bitmap namespace until this work physically returns.
                executor.execute {
                    try {
                        runCatching {
                            val bitmap = requireImage(imageKey)
                            encodeBody(requestId, bitmap) ?: encode(bitmap)
                        }.onSuccess { onSuccess(requestId, it) }
                            .onFailure { failEncoding(requestId, it) }
                    } finally {
                        work.finish()
                        if (!closed.get()) onEncoded(requestId)
                    }
                }
            } catch (error: Throwable) {
                try {
                    failEncoding(requestId, error)
                } finally {
                    work.finish()
                    if (!closed.get()) onEncoded(requestId)
                }
            }
        }

        private fun failEncoding(requestId: String, error: Throwable) {
            if (!closed.get()) onFailure(
                requestId,
                "venera-operation-failed",
                error.message ?: "Venera image encode failed",
            )
        }

        @JavascriptInterface
        fun fail(requestId: String, code: String, message: String) = withNativeWork {
            if (!closed.get()) onFailure(requestId, code, message)
        }

        @JavascriptInterface
        fun finished(requestId: String) = withNativeWork {
            if (!closed.get()) onFinished(requestId)
        }

        private inline fun withNativeWork(action: () -> Unit) {
            val work = nativeWork.begin() ?: return
            try {
                action()
            } finally {
                work.finish()
            }
        }

        override fun close() {
            closeWhenDrained()
        }

        fun closeWhenDrained(): CompletableFuture<Unit> {
            if (!closed.compareAndSet(false, true)) return closeCompletion
            nativeWork.close().whenComplete { _, failure ->
                runCatching {
                    releaseImages()
                    if (failure != null) throw failure
                }.fold(
                    onSuccess = { closeCompletion.complete(Unit) },
                    onFailure = { closeCompletion.completeExceptionally(it) },
                )
            }
            return closeCompletion
        }

        private fun image(message: JSONObject): Any? = when (message.getString("function")) {
            "decodeInput" -> {
                val requestId = message.getString("requestId")
                val bytes = takeInput(requestId)
                    ?: error("Venera isolated transform input is unavailable")
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    ?: error("Venera image decode failed")
                requireImageSize(bitmap.width, bitmap.height)
                retainImage(bitmap)
            }
            "copyRange" -> {
                val source = requireImage(message.getInt("key"))
                val x = message.getInt("x")
                val y = message.getInt("y")
                val width = message.getInt("width")
                val height = message.getInt("height")
                require(x >= 0 && y >= 0 && width > 0 && height > 0 &&
                    x + width <= source.width && y + height <= source.height) {
                    "Venera image crop is out of bounds"
                }
                retainImage(Bitmap.createBitmap(source, x, y, width, height))
            }
            "copyAndRotate90" -> {
                val source = requireImage(message.getInt("key"))
                val matrix = Matrix().apply { postRotate(90f) }
                retainImage(
                    Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true),
                )
            }
            "fillImageAt" -> {
                val target = requireImage(message.getInt("key"))
                val source = requireImage(message.getInt("image"))
                require(target.isMutable) { "Venera target image is immutable" }
                Canvas(target).drawBitmap(
                    source,
                    message.getInt("x").toFloat(),
                    message.getInt("y").toFloat(),
                    null,
                )
                null
            }
            "fillImageRangeAt" -> {
                val target = requireImage(message.getInt("key"))
                val source = requireImage(message.getInt("image"))
                require(target.isMutable) { "Venera target image is immutable" }
                val srcX = message.getInt("srcX")
                val srcY = message.getInt("srcY")
                val width = message.getInt("width")
                val height = message.getInt("height")
                val x = message.getInt("x")
                val y = message.getInt("y")
                val emptyRange = validateVeneraImageFillRange(
                    targetWidth = target.width,
                    targetHeight = target.height,
                    sourceWidth = source.width,
                    sourceHeight = source.height,
                    x = x,
                    y = y,
                    srcX = srcX,
                    srcY = srcY,
                    width = width,
                    height = height,
                )
                if (!emptyRange) {
                    Canvas(target).drawBitmap(
                        source,
                        Rect(srcX, srcY, srcX + width, srcY + height),
                        Rect(x, y, x + width, y + height),
                        null,
                    )
                }
                null
            }
            "getWidth" -> requireImage(message.getInt("key")).width
            "getHeight" -> requireImage(message.getInt("key")).height
            "emptyImage" -> {
                val width = message.getInt("width")
                val height = message.getInt("height")
                requireImageSize(width, height)
                retainImage(Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888))
            }
            "disposeAll" -> {
                releaseImages()
                null
            }
            else -> error("unsupported isolated Venera image operation")
        }

        private fun encode(bitmap: Bitmap): ByteArray {
            val output = ByteArrayOutputStream()
            require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                "Venera image encode failed"
            }
            return output.toByteArray().also {
                require(it.size <= maxResponseBytes) {
                    "Venera transformed image exceeds runtime limit"
                }
            }
        }

        private fun retainImage(bitmap: Bitmap): Int {
            requireImageSize(bitmap.width, bitmap.height)
            val key = nextImageKey.getAndIncrement()
            require(key > 0) { "Venera image identity exhausted" }
            images[key] = bitmap
            return key
        }

        private fun requireImage(key: Int): Bitmap =
            images[key] ?: error("Venera image handle is invalid")

        private fun requireImageSize(width: Int, height: Int) {
            require(width > 0 && height > 0 &&
                width.toLong() * height.toLong() <= MAX_IMAGE_PIXELS) {
                "Venera image dimensions exceed runtime limit"
            }
        }

        private fun releaseImages() {
            images.values.forEach { bitmap -> runCatching { bitmap.recycle() } }
            images.clear()
        }
    }

    companion object {
        private const val BRIDGE_NAME = "ZicTransform"
        private const val LOG_TAG = "ZicVeneraTransform"
        private const val INITIALIZATION_TIMEOUT_MILLIS = 5_000L
        private const val MAX_IMAGE_PIXELS = 32L * 1024L * 1024L

        private val TRANSFORM_BOOTSTRAP = """
const __zicImageEncodingReplies = new Map();
function __zicEncodeImageTransform(requestId, imageKey) {
  return new Promise(resolve => {
    __zicImageEncodingReplies.set(requestId, resolve);
    ZicTransform.complete(requestId, imageKey);
  });
}
function __zicImageTransformEncoded(requestId) {
  const resolve = __zicImageEncodingReplies.get(requestId);
  __zicImageEncodingReplies.delete(requestId);
  if (resolve) resolve();
}
function __zicImageRequest(message) {
  const response = JSON.parse(ZicTransform.request(JSON.stringify(message)));
  if (!response.ok) throw new Error(String(response.message || 'Venera image operation failed'));
  return response.value;
}
class Image {
  constructor(key){this.key=key}
  copyRange(x,y,width,height){const key=__zicImageRequest({function:'copyRange',key:this.key,x,y,width,height});return key==null?null:new Image(key)}
  copyAndRotate90(){const key=__zicImageRequest({function:'copyAndRotate90',key:this.key});return key==null?null:new Image(key)}
  fillImageAt(x,y,image){__zicImageRequest({function:'fillImageAt',key:this.key,x,y,image:image.key})}
  fillImageRangeAt(x,y,image,srcX,srcY,width,height){__zicImageRequest({function:'fillImageRangeAt',key:this.key,x,y,image:image.key,srcX,srcY,width,height})}
  get width(){return __zicImageRequest({function:'getWidth',key:this.key})}
  get height(){return __zicImageRequest({function:'getHeight',key:this.key})}
  static empty(width,height){return new Image(__zicImageRequest({function:'emptyImage',width,height}))}
}
async function __zicRunImageTransform(requestId, script) {
  try {
    const sourceKey = __zicImageRequest({function:'decodeInput',requestId});
    const modifier = (0,eval)(String(script)+'\n;(typeof modifyImage==="function"?modifyImage:null)');
    if (typeof modifier !== 'function') throw new Error('Venera modifyImage script defines no modifyImage function');
    const transformed = await Promise.resolve(modifier(new Image(sourceKey)));
    if (!transformed || typeof transformed.key !== 'number') throw new Error('Venera modifyImage returned no Image');
    await __zicEncodeImageTransform(requestId, transformed.key);
  } catch (error) {
    const incompatible = error instanceof ReferenceError;
    ZicTransform.fail(
      requestId,
      incompatible ? 'venera-isolated-transform-incompatible' : 'venera-operation-failed',
      String(error?.message || error || 'Venera isolated transform failed'),
    );
  } finally {
    try { __zicImageRequest({function:'disposeAll'}); } catch (_) {}
    ZicTransform.finished(requestId);
  }
}
"""
    }
}
