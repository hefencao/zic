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
import java.util.concurrent.ConcurrentHashMap
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
 * UI-less image-only JavaScript context for source-provided Venera
 * `modifyImage` programs.
 *
 * It deliberately does not load the source script and exposes no Network,
 * Cookie, settings or source-data bridge. The canonical source WebView remains
 * physically single-invocation; this context only lets CPU-heavy bitmap
 * transforms overlap request-plan resolution without changing source state.
 */
internal class VeneraImageTransformRuntime(
    context: Context,
    private val driverId: String,
    private val maxResponseBytes: Int,
) : Closeable {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pending = ConcurrentHashMap<String, NativeDriverResult>()
    private val inputs = ConcurrentHashMap<String, ByteArray>()
    private val completions = ConcurrentHashMap<String, Completion>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val started = ConcurrentHashMap.newKeySet<String>()
    private val startedAtNanos = ConcurrentHashMap<String, Long>()
    private val closed = AtomicBoolean(false)
    private val bridge = TransformBridge(
        maxResponseBytes = maxResponseBytes,
        takeInput = { requestId -> inputs.remove(requestId) },
        onSuccess = { requestId, bytes ->
            completions[requestId] = Completion.Success(bytes)
        },
        onFailure = { requestId, code, message ->
            completions[requestId] = Completion.Failure(code, message)
        },
        onFinished = ::finish,
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
    ) {
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
        if (pending.putIfAbsent(requestId, result) != null) {
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
            if (closed.get()) {
                finishUnavailable(requestId, "Venera image transform runtime is closing")
                return@post
            }
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
            completions.remove(requestId)
            val result = pending.remove(requestId) ?: return
            cancelled.remove(requestId)
            startedAtNanos.remove(requestId)
            result.error("runtime-request-cancelled", "Venera request was cancelled")
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val finishClose = {
            pending.keys.toList().forEach { requestId ->
                queuedScripts.remove(requestId)
                inputs.remove(requestId)
                completions.remove(requestId)
                started.remove(requestId)
                cancelled.remove(requestId)
                startedAtNanos.remove(requestId)
                pending.remove(requestId)?.error(
                    "runtime-closing",
                    "Venera image transform runtime is closing",
                )
            }
            bridge.close()
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
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            finishClose()
        } else {
            val latch = java.util.concurrent.CountDownLatch(1)
            mainHandler.post {
                finishClose()
                latch.countDown()
            }
            latch.await()
        }
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
        inputs.remove(requestId)
        started.remove(requestId)
        val result = pending.remove(requestId) ?: run {
            completions.remove(requestId)
            cancelled.remove(requestId)
            startedAtNanos.remove(requestId)
            return
        }
        val elapsedMicros = startedAtNanos.remove(requestId)?.let { startedAt ->
            (SystemClock.elapsedRealtimeNanos() - startedAt) / 1_000L
        }
        if (cancelled.remove(requestId)) {
            completions.remove(requestId)
            result.error("runtime-request-cancelled", "Venera request was cancelled")
            return
        }
        when (val completion = completions.remove(requestId)) {
            is Completion.Success -> {
                Log.i(
                    LOG_TAG,
                    "isolated-transform-finish driver=$driverId request=$requestId " +
                        "elapsedMicros=${elapsedMicros ?: -1} outputBytes=${completion.bytes.size}",
                )
                result.success(completion.bytes)
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
        completions.remove(requestId)
        started.remove(requestId)
        cancelled.remove(requestId)
        startedAtNanos.remove(requestId)
        pending.remove(requestId)?.error(
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

    private sealed interface Completion {
        data class Success(val bytes: ByteArray) : Completion
        data class Failure(val code: String, val message: String) : Completion
    }

    private class TransformBridge(
        private val maxResponseBytes: Int,
        private val takeInput: (String) -> ByteArray?,
        private val onSuccess: (String, ByteArray) -> Unit,
        private val onFailure: (String, String, String) -> Unit,
        private val onFinished: (String) -> Unit,
    ) : Closeable {
        private val images = ConcurrentHashMap<Int, Bitmap>()
        private val nextImageKey = AtomicInteger(1)
        private val closed = AtomicBoolean(false)

        @JavascriptInterface
        fun request(raw: String): String {
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
            runCatching { encode(requireImage(imageKey)) }
                .onSuccess { onSuccess(requestId, it) }
                .onFailure {
                    onFailure(
                        requestId,
                        "venera-operation-failed",
                        it.message ?: "Venera image encode failed",
                    )
                }
        }

        @JavascriptInterface
        fun fail(requestId: String, code: String, message: String) {
            onFailure(requestId, code, message)
        }

        @JavascriptInterface
        fun finished(requestId: String) {
            onFinished(requestId)
        }

        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            releaseImages()
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
    ZicTransform.complete(requestId, transformed.key);
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
