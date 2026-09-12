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
import android.webkit.CookieManager
import dev.zic.network.AndroidBrowserCookieSession
import android.webkit.JavascriptInterface
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.net.URL
import java.security.KeyFactory
import java.security.MessageDigest
import java.util.Locale
import java.nio.charset.Charset
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

private const val VENERA_RUNTIME_LOG_TAG = "ZicPluginRuntime"

private fun veneraActivationLog(
    driverId: String,
    stage: String,
    startedAt: Long,
    stageStarted: Long,
    detail: String? = null,
) {
    if (!Log.isLoggable(VENERA_RUNTIME_LOG_TAG, Log.DEBUG)) return
    val now = SystemClock.elapsedRealtime()
    Log.d(
        VENERA_RUNTIME_LOG_TAG,
        "venera-activation driver=$driverId stage=$stage " +
            "stageMs=${now - stageStarted} totalMs=${now - startedAt}" +
            (detail?.let { " $it" } ?: ""),
    )
}

/** Venera JavaScript runtime hosted by a process-private, UI-less WebView. */
internal class VeneraRuntimeDriver private constructor(
    private val context: Context,
    override val driverId: String,
    override val runtimeId: String,
    private val sourceKey: String,
    private val webView: WebView,
    private val bridge: VeneraNativeBridge,
    override val sources: List<Map<String, Any?>>,
) : NativeExternalPluginDriver {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pending = ConcurrentHashMap<String, NativeDriverResult>()
    private val cancelledRequests = ConcurrentHashMap.newKeySet<String>()
    private val closed = AtomicBoolean(false)

    init {
        bridge.resultSink = resultSink@ { requestId, envelope ->
            val result = pending.remove(requestId) ?: return@resultSink
            val ok = envelope.optBoolean("ok", false)
            if (!ok) {
                result.error(
                    envelope.optString("code", "venera-operation-failed"),
                    envelope.optString("message", "Venera operation failed").take(300),
                    envelope.optBoolean("retryable", false),
                )
            } else {
                val decoded = decodeWireValue(envelope.opt("value"))
                val nativeToken = (decoded as? Map<*, *>)
                    ?.get("__zicNativeBytesToken") as? String
                if (nativeToken.isNullOrBlank()) {
                    result.success(decoded ?: emptyMap<String, Any?>())
                } else {
                    val bytes = bridge.takeNativeBytes(nativeToken)
                    if (bytes == null) {
                        result.error(
                            "venera-native-bytes-missing",
                            "Venera native image payload is unavailable",
                        )
                    } else {
                        result.success(bytes)
                    }
                }
            }
        }
        // Scheduler cancellation is complete only after the JavaScript
        // invocation has actually unwound. Returning a cancelled result while
        // the old async promise kept running let a new current request enter
        // the same WebView context concurrently; the request-scoped Network
        // bridge then had no safe async-local identity. Abort native I/O first
        // and return the runtime permit from the `finished` callback instead.
        bridge.finishedSink = finishedSink@ { requestId ->
            val result = pending.remove(requestId) ?: run {
                cancelledRequests.remove(requestId)
                return@finishedSink
            }
            if (cancelledRequests.remove(requestId)) {
                result.error(
                    "runtime-request-cancelled",
                    "Venera request was cancelled",
                )
            } else {
                result.error(
                    "venera-result-missing",
                    "Venera invocation finished without a protocol result",
                )
            }
        }
    }

    override fun invoke(request: Map<String, Any?>, result: NativeDriverResult) {
        if (closed.get()) {
            result.error("runtime-closing", "Venera runtime is closing")
            return
        }
        val requestId = request.requireString("requestId")
        if (request.requireString("externalSourceId") != sourceKey) {
            result.error("source-missing", "Venera source is not active")
            return
        }
        pending[requestId] = result
        val encoded = JSONObject(request).toString().jsQuoted()
        mainHandler.post {
            if (closed.get()) {
                pending.remove(requestId)?.error("runtime-closing", "Venera runtime is closing")
                return@post
            }
            webView.evaluateJavascript("__zicInvoke($encoded);", null)
        }
    }

    override fun cancel(requestId: String) {
        if (!pending.containsKey(requestId)) return
        cancelledRequests.add(requestId)
        // This requestId belongs to the JavaScript request-plan invocation, not
        // to the final image-body transport. Cancel bridge work that the source
        // hook itself started (for example Network.* inside onImageLoad), then
        // mark the JavaScript plan invocation cancelled below. The final image
        // HTTP response is opened later by SourceResourceTransport under the
        // scheduler TaskControl and is cancelled by that transport instead.
        // The JavaScript promise remains the physical owner of the single Venera
        // context and must reach `finished` before the next invocation gets it.
        bridge.cancel(requestId)
        mainHandler.post {
            webView.evaluateJavascript("__zicCancel(${requestId.jsQuoted()});", null)
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        pending.keys.toList().forEach(bridge::cancel)
        pending.values.forEach {
            it.error("runtime-closing", "Venera runtime is closing")
        }
        pending.clear()
        cancelledRequests.clear()
        bridge.close()
        if (Looper.myLooper() == Looper.getMainLooper()) {
            destroyWebView()
        } else {
            val latch = java.util.concurrent.CountDownLatch(1)
            mainHandler.post {
                destroyWebView()
                latch.countDown()
            }
            latch.await()
        }
    }

    private fun destroyWebView() {
        webView.removeJavascriptInterface(BRIDGE_NAME)
        webView.stopLoading()
        webView.loadUrl("about:blank")
        webView.clearHistory()
        webView.removeAllViews()
        webView.destroy()
    }

    companion object {
        private const val BRIDGE_NAME = "ZicNative"
        private const val ACTIVATION_TIMEOUT_MILLIS = 10_000L

        @SuppressLint("SetJavaScriptEnabled")
        fun create(
            context: Context,
            driverId: String,
            activation: Map<String, Any?>,
            payloadPath: String,
            payloadLength: Long,
            payloadSha256: String,
            executor: ExecutorService,
            resolverHttp: VeneraResolverHttpTransport,
            networkCache: VeneraHttpCacheStore,
            callback: (Result<VeneraRuntimeDriver>) -> Unit,
        ) {
            check(Looper.myLooper() == Looper.getMainLooper())
            val startedAt = SystemClock.elapsedRealtime()
            var stageStarted = startedAt
            veneraActivationLog(driverId, "start", startedAt, stageStarted)
            val prepared = runCatching {
                val payload = File(payloadPath)
                verifyVeneraPayload(payload, payloadLength, payloadSha256)
                veneraActivationLog(driverId, "payload-verified", startedAt, stageStarted)
                stageStarted = SystemClock.elapsedRealtime()
                val script = payload.readText(Charsets.UTF_8)
                val className = Regex(
                    "class\\s+([A-Za-z_$][A-Za-z0-9_$]*)\\s+extends\\s+ComicSource",
                ).find(script)?.groupValues?.get(1)
                    ?: error("Venera script does not declare a ComicSource subclass")
                val sourceKey = activation.requireString("sourceKey")
                val pluginId = activation.requireString("pluginId")
                val pluginVersion = activation.requireString("pluginVersion")
                veneraActivationLog(
                    driverId,
                    "metadata-ready",
                    startedAt,
                    stageStarted,
                    "plugin=$pluginId source=$sourceKey",
                )
                val capabilities = activation["capabilities"].asVeneraCapabilities()
                val limits = activation["limits"].stringMap("runtime limits")
                val maxResponseBytes = limits.requireLong("maxResponseBytes")
                    .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                veneraActivationLog(driverId, "webview-create-start", startedAt, stageStarted)
                stageStarted = SystemClock.elapsedRealtime()
                val webView = WebView(context)
                veneraActivationLog(driverId, "webview-created", startedAt, stageStarted)
                webView.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = false
                    databaseEnabled = false
                    allowFileAccess = false
                    allowContentAccess = false
                    javaScriptCanOpenWindowsAutomatically = false
                    setSupportMultipleWindows(false)
                    mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                    cacheMode = WebSettings.LOAD_NO_CACHE
                    userAgentString = "${userAgentString.orEmpty()} zic-venera/$pluginVersion".trim()
                }
                val bridge = VeneraNativeBridge(
                    context = context,
                    webView = webView,
                    executor = executor,
                    driverId = driverId,
                    sourceKey = sourceKey,
                    capabilities = capabilities,
                    maxResponseBytes = maxResponseBytes,
                    defaultUserAgent = webView.settings.userAgentString.orEmpty(),
                    resolverHttp = resolverHttp,
                    networkCache = networkCache,
                    networkCacheNamespace = VeneraHttpCacheNamespace(
                        pluginId = pluginId,
                        pluginVersion = pluginVersion,
                        sourceKey = sourceKey,
                    ),
                )
                webView.addJavascriptInterface(bridge, BRIDGE_NAME)
                VeneraActivation(
                    webView = webView,
                    bridge = bridge,
                    script = script,
                    className = className,
                    sourceKey = sourceKey,
                    pluginId = pluginId,
                    pluginVersion = pluginVersion,
                )
            }
            prepared.onFailure {
                veneraActivationLog(driverId, "failed-${it.javaClass.simpleName}", startedAt, stageStarted)
                callback(Result.failure(it))
            }
            val state = prepared.getOrNull() ?: return
            val completed = AtomicBoolean(false)
            val activationStarted = AtomicBoolean(false)
            val mainHandler = Handler(Looper.getMainLooper())

            fun finish(result: Result<VeneraRuntimeDriver>) {
                if (!completed.compareAndSet(false, true)) return
                state.bridge.activationSink = null
                veneraActivationLog(
                    driverId,
                    if (result.isSuccess) "complete" else "failed",
                    startedAt,
                    stageStarted,
                )
                if (result.isFailure) {
                    state.bridge.close()
                    state.webView.removeJavascriptInterface(BRIDGE_NAME)
                    state.webView.stopLoading()
                    state.webView.destroy()
                }
                callback(result)
            }

            state.bridge.activationSink = { envelope ->
                veneraActivationLog(driverId, "activation-envelope", startedAt, stageStarted)
                mainHandler.post {
                    finish(
                        runCatching {
                            require(envelope.optBoolean("ok")) {
                                envelope.optString("message", "Venera source init failed")
                            }
                            val discoveredKey = envelope.optString("key")
                            require(discoveredKey == state.sourceKey) {
                                "Venera source key changed during activation"
                            }
                            val name = envelope.optString("name").ifBlank { discoveredKey }
                            val website = envelope.optString("url")
                                .takeIf { it.startsWith("https://") || it.startsWith("http://") }
                                ?: "https://zic.runtime.invalid/"
                            val supportsSearch = envelope.optBoolean("supportsSearch", false)
                            VeneraRuntimeDriver(
                                context = context,
                                driverId = driverId,
                                runtimeId = "venera:${state.pluginId}:${state.pluginVersion}",
                                sourceKey = discoveredKey,
                                webView = state.webView,
                                bridge = state.bridge,
                                sources = listOf(
                                    mapOf(
                                        "externalId" to discoveredKey,
                                        "name" to name,
                                        "language" to "und",
                                        "website" to website,
                                        "supportsSearch" to supportsSearch,
                                        "supportsComicPreview" to envelope.optBoolean(
                                            "supportsComicPreview",
                                            false,
                                        ),
                                        "supportsComicComments" to envelope.optBoolean(
                                            "supportsComicComments",
                                            false,
                                        ),
                                        "browserUserAgent" to
                                            state.webView.settings.userAgentString.orEmpty(),
                                        "contentRatings" to listOf("safe", "suggestive"),
                                    ),
                                ),
                            )
                        },
                    )
                }
            }
            state.webView.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    if (completed.get() || !activationStarted.compareAndSet(false, true)) return
                    veneraActivationLog(driverId, "page-finished", startedAt, stageStarted)
                    stageStarted = SystemClock.elapsedRealtime()
                    view.evaluateJavascript(state.activationScript(), null)
                }
            }
            state.webView.loadDataWithBaseURL(
                "https://zic.runtime.invalid/",
                "<html><head></head><body></body></html>",
                "text/html",
                "utf-8",
                null,
            )
            mainHandler.postDelayed(
                {
                    finish(Result.failure(IllegalStateException("Venera source activation timed out")))
                },
                ACTIVATION_TIMEOUT_MILLIS,
            )
        }
    }

}


private data class VeneraActivation(
    val webView: WebView,
    val bridge: VeneraNativeBridge,
    val script: String,
    val className: String,
    val sourceKey: String,
    val pluginId: String,
    val pluginVersion: String,
) {
    fun activationScript(): String = buildString {
        append(VENERA_BOOTSTRAP)
        append("\n")
        append(script)
        append("\n;(async()=>{try{globalThis.__zicSource=new ")
        append(className)
        append("();ZicNative.activationTrace('source-created');__zicInstallSourceData(__zicSource);ZicNative.activationTrace('source-data-installed');")
        append("ZicNative.activationTrace('init-start');await Promise.resolve(__zicSource.init?.());ZicNative.activationTrace('init-complete');__zicActivationOpen=false;")
        append("if(__zicCompareVersion(String(__zicSource.minAppVersion||'0'),appVersion)>0)")
        append("throw new Error('Venera source requires app '+__zicSource.minAppVersion+' or newer');")
        append("const __browse=__zicHasBrowseCapability(__zicSource);")
        append("if(!__browse)throw new Error('Venera source exposes no compatible browse capability');")
        append("ZicNative.activationTrace('capabilities-ready');")
        append("ZicNative.activated(JSON.stringify({ok:true,key:String(__zicSource.key||''),")
        append("name:String(__zicSource.name||''),url:String(__zicSource.url||''),")
        append("supportsBrowse:__browse,supportsSearch:__zicHasSearchCapability(__zicSource),")
        append("supportsComicPreview:typeof __zicSource.comic?.loadThumbnails==='function',")
        append("supportsComicComments:typeof __zicSource.comic?.loadComments==='function'}));")
        append("}catch(e){__zicActivationOpen=false;ZicNative.activated(JSON.stringify({ok:false,")
        append("message:__zicErrorMessage(e,'activation')}));}})();")
    }
}

private class VeneraNativeBridge(
    context: Context,
    private val webView: WebView,
    private val executor: ExecutorService,
    private val driverId: String,
    private val sourceKey: String,
    private val capabilities: Set<String>,
    private val maxResponseBytes: Int,
    private val defaultUserAgent: String,
    private val resolverHttp: VeneraResolverHttpTransport,
    private val networkCache: VeneraHttpCacheStore,
    private val networkCacheNamespace: VeneraHttpCacheNamespace,
) : Closeable {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(
        "zic_venera_${sourceKey.replace(Regex("[^A-Za-z0-9_.-]"), "_")}",
        Context.MODE_PRIVATE,
    )
    private val images = ConcurrentHashMap<Int, Bitmap>()
    private val nextImageKey = AtomicInteger(1)
    private val nativeBytes = LinkedHashMap<String, ByteArray>()
    private val cookieManager = CookieManager.getInstance()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val asyncCalls = ConcurrentHashMap<String, String>()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    @Volatile var resultSink: ((String, JSONObject) -> Unit)? = null
    @Volatile var finishedSink: ((String) -> Unit)? = null
    @Volatile var activationSink: ((JSONObject) -> Unit)? = null

    @JavascriptInterface
    fun request(raw: String): String {
        var method = "unknown"
        var activationCall = false
        var startedAt = 0L
        val response = runCatching {
            val message = JSONObject(raw)
            method = message.optString("method", "unknown")
            activationCall = !message.has("requestId")
            if (activationCall) startedAt = SystemClock.elapsedRealtime()
            val value = execute(message)
            JSONObject().put("ok", true).put("value", encodeWireValue(value)).toString()
        }.getOrElse { error ->
            JSONObject()
                .put("ok", false)
                .put("error", error.sanitizedMessage())
                .toString()
        }
        if (activationCall && startedAt != 0L) {
            veneraActivationLog(
                driverId = driverId,
                stage = "activation-bridge",
                startedAt = startedAt,
                stageStarted = startedAt,
                detail = "method=$method",
            )
        }
        return response
    }

    /**
     * HTTP is the only bridge operation that may wait on origin I/O. Keep it
     * off the WebView JavascriptInterface thread and return its envelope by a
     * main-thread evaluateJavascript callback. The executor is the native
     * runtime host's worker pool; it does not add a second network scheduler.
     */
    @JavascriptInterface
    fun requestAsync(raw: String) {
        val message = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val callId = message.optString("bridgeCallId")
            .trim()
            .takeIf { it.isNotEmpty() }
            ?: return
        val requestId = message.optString("requestId")
            .trim()
            .takeIf { it.isNotEmpty() }
        val transportRequestId = requestId ?: "venera-bridge-$callId"
        val executeMessage = if (requestId == null) {
            JSONObject(message.toString()).put("requestId", transportRequestId)
        } else {
            message
        }
        asyncCalls[callId] = transportRequestId
        try {
            executor.execute {
                val startedAt = SystemClock.elapsedRealtime()
                val response = runCatching {
                    require(executeMessage.optString("method") in setOf("http", "http_binary", "http_image_binary")) {
                        "Venera asynchronous bridge only supports HTTP"
                    }
                    if (cancelled.contains(transportRequestId)) {
                        error("Venera request was cancelled")
                    }
                    val value = execute(executeMessage)
                    JSONObject().put("ok", true).put("value", encodeWireValue(value))
                }.getOrElse { error ->
                    JSONObject()
                        .put("ok", false)
                        .put("error", error.sanitizedMessage())
                }
                asyncCalls.remove(callId)
                if (requestId == null) {
                    veneraActivationLog(
                        driverId = driverId,
                        stage = "activation-async-bridge",
                        startedAt = startedAt,
                        stageStarted = startedAt,
                        detail = "method=${message.optString("method", "unknown")}",
                    )
                }
                postAsyncResponse(callId, response)
            }
        } catch (error: Throwable) {
            asyncCalls.remove(callId)
            postAsyncResponse(
                callId,
                JSONObject()
                    .put("ok", false)
                    .put("error", error.sanitizedMessage()),
            )
        }
    }

    private fun postAsyncResponse(callId: String, response: JSONObject) {
        mainHandler.post {
            if (closed) return@post
            webView.evaluateJavascript(
                "__zicBridgeResponse(${JSONObject.quote(callId)}," +
                    "${JSONObject.quote(response.toString())});",
                null,
            )
        }
    }

    private fun execute(message: JSONObject): Any? = when (message.getString("method")) {
        "http" -> http(message)
        "http_binary" -> httpBinary(message, requireImage = false)
        "http_image_binary" -> httpBinary(message, requireImage = true)
        "cookie" -> cookie(message)
        "load_data" -> loadData(message)
        "save_data" -> saveData(message)
        "delete_data" -> deleteData(message)
        "load_setting" -> loadSetting(message)
        "save_setting" -> saveSetting(message)
        "convert" -> convert(message)
        "uuid" -> UUID.randomUUID().toString()
        "random" -> random(message)
        "delay" -> error(
            "Venera delay must be handled asynchronously by the JavaScript bridge",
        )
        "getLocale" -> Locale.getDefault().toLanguageTag().replace('-', '_')
        "getPlatform" -> "android"
        "isLogged" -> isLogged()
        "log" -> null
        "image" -> image(message)
        "UI", "setClipboard", "getClipboard", "compute" ->
            error("Venera capability is not available in background source runtime")
        else -> error("unsupported Venera bridge method")
    }

    @JavascriptInterface
    fun activationTrace(stage: String) {
        if (!Log.isLoggable(VENERA_RUNTIME_LOG_TAG, Log.DEBUG)) return
        Log.d(
            VENERA_RUNTIME_LOG_TAG,
            "venera-activation driver=$driverId stage=js-${stage.take(80)}",
        )
    }

    @JavascriptInterface
    fun activated(rawEnvelope: String) {
        val envelope = runCatching { JSONObject(rawEnvelope) }.getOrElse {
            JSONObject()
                .put("ok", false)
                .put("message", "Venera returned an invalid activation result")
        }
        activationSink?.invoke(envelope)
    }

    @JavascriptInterface
    fun complete(requestId: String, rawEnvelope: String) {
        if (cancelled.remove(requestId)) return
        runCatching { JSONObject(rawEnvelope) }
            .onSuccess { resultSink?.invoke(requestId, it) }
            .onFailure {
                resultSink?.invoke(
                    requestId,
                    JSONObject()
                        .put("ok", false)
                        .put("code", "venera-result-invalid")
                        .put("message", "Venera returned an invalid result"),
                )
            }
    }

    @JavascriptInterface
    fun finished(requestId: String) {
        cancelled.remove(requestId)
        finishedSink?.invoke(requestId)
    }

    fun cancel(requestId: String) {
        cancelled.add(requestId)
        resolverHttp.cancel(requestId)
    }

    private fun http(message: JSONObject): Any =
        performHttp(message).toWire(message.optBoolean("bytes"))

    private fun httpBinary(message: JSONObject, requireImage: Boolean): Any {
        val response = performHttp(message)
        val result = JSONObject()
            .put("status", response.status)
            .put("headers", response.headers)
        if (response.status in 200..299) {
            if (!requireImage) {
                // Public Network.fetchBinary is a general binary API. Image
                // semantics belong only to the private loadResource fast path.
                result.put("nativeBytesToken", retainNativeBytes(response.body))
                return result
            }
            val encodedImage = hasVeneraEncodedImageSignature(response.body)
            result
                .put("encodedImage", encodedImage)
                .put("bodyLength", response.body.size)
            // Invalid image bodies must stay outside the native-byte token
            // registry. The Venera source still owns semantic image recovery
            // through onLoadFailed; retaining an HTML/error body here would
            // both leak a token and report a successful image operation.
            if (encodedImage) {
                result.put("nativeBytesToken", retainNativeBytes(response.body))
            } else {
                networkCache.invalidate(
                    namespace = networkCacheNamespace,
                    url = message.getString("url"),
                )
            }
        }
        return result
    }

    private fun performHttp(message: JSONObject): VeneraHttpResponse {
        requireCapability("network")
        val requestId = message.optString("requestId")
            .takeIf { it.isNotBlank() }
        if (requestId != null && cancelled.contains(requestId)) {
            error("Venera request was cancelled")
        }
        val rawUrl = message.getString("url")
        require(rawUrl.startsWith("https://") || rawUrl.startsWith("http://")) {
            "Venera network URL must use HTTP(S)"
        }
        var target = URL(rawUrl)
        var method = message.optString("http_method", "GET").uppercase(Locale.US)
        val rawHeaders = message.optJSONObject("headers")
        val cacheTime = rawHeaders.veneraControlHeader("cache-time")
        val forceResolverCacheMiss = message.optBoolean("__zicFreshResolver", false)
        // `cache-time` and `prevent-parallel` are Venera Network.* control
        // fields, not origin HTTP headers. The source runtime is physically
        // single-invocation, so prevent-parallel is already stronger than the
        // upstream same-path exclusion contract; strip both controls before
        // opening native HTTP.
        val forwardHeaders = veneraRequestHeaders(
            rawHeaders,
            defaultUserAgent,
        )
        val cacheUrl = target.toExternalForm()
        val cacheEligible = method == "GET"
        var cacheRequestHeaders: Map<String, String>? = null
        val data = decodeWireValue(message.opt("data"))
        var bodyBytes = when (data) {
            null -> ByteArray(0)
            is ByteArray -> data
            is String -> data.toByteArray(Charsets.UTF_8)
            else -> JSONObject.wrap(data).toString().toByteArray(Charsets.UTF_8)
        }
        if (method in setOf("GET", "HEAD")) {
            bodyBytes = ByteArray(0)
            forwardHeaders.removeVeneraHeader("content-length")
            forwardHeaders.removeVeneraHeader("content-type")
            forwardHeaders.removeVeneraHeader("transfer-encoding")
        } else {
            require(bodyBytes.size <= VENERA_HTTP_MAX_REQUEST_BYTES) {
                "Venera request body exceeds $VENERA_HTTP_MAX_REQUEST_BYTES bytes"
            }
            if (forwardHeaders.keys.none {
                    it.equals("content-type", ignoreCase = true)
                }
            ) {
                forwardHeaders["Content-Type"] = "application/octet-stream"
            }
        }
        repeat(VENERA_HTTP_MAX_REDIRECTS + 1) { redirectCount ->
            if (requestId != null && cancelled.contains(requestId)) {
                error("Venera request was cancelled")
            }
            val targetIdentity = target.toExternalForm()
            if (capabilities.contains("cookies")) {
                AndroidBrowserCookieSession.importCookies(
                    appContext,
                    targetIdentity,
                    expectedUserAgent = defaultUserAgent,
                )
            }
            val requestHeaders = LinkedHashMap(forwardHeaders)
            if (capabilities.contains("cookies")) {
                val storedCookies = cookieManager.getCookie(targetIdentity)
                val cookieHeader = requestHeaders.keys
                    .firstOrNull { it.equals("cookie", ignoreCase = true) }
                val mergedCookies = mergeVeneraCookieHeaders(
                    explicit = cookieHeader?.let(requestHeaders::get),
                    stored = storedCookies,
                )
                if (mergedCookies != null) {
                    requestHeaders[cookieHeader ?: "Cookie"] = mergedCookies
                }
            }
            if (cacheEligible && redirectCount == 0) {
                cacheRequestHeaders = LinkedHashMap(requestHeaders)
                val cached = networkCache.lookup(
                    namespace = networkCacheNamespace,
                    url = cacheUrl,
                    requestHeaders = requestHeaders,
                    cacheTime = cacheTime,
                    forceMiss = forceResolverCacheMiss,
                )
                if (requestId == null && Log.isLoggable(VENERA_RUNTIME_LOG_TAG, Log.DEBUG)) {
                    val cacheState = if (cached == null) "miss" else "hit"
                    val cacheMode = cacheTime ?: "default"
                    Log.d(
                        VENERA_RUNTIME_LOG_TAG,
                        "venera-activation driver=$driverId stage=http-cache-" +
                            "$cacheState cacheTime=$cacheMode",
                    )
                }
                cached?.let { return it }
            }
            val result = executeHttpRequest(
                target = target,
                method = method,
                headers = requestHeaders,
                bodyBytes = bodyBytes,
                requestId = requestId,
            )
            persistResponseCookies(targetIdentity, result.headers)
            val location = result.headers
                .veneraHeaderValue("location")
                ?.trim()
                .orEmpty()
            if (result.status !in VENERA_HTTP_REDIRECT_STATUSES ||
                location.isEmpty()
            ) {
                if (cacheEligible) {
                    cacheRequestHeaders?.let { headers ->
                        networkCache.store(
                            namespace = networkCacheNamespace,
                            url = cacheUrl,
                            requestHeaders = headers,
                            response = result,
                        )
                    }
                }
                return result
            }
            require(redirectCount < VENERA_HTTP_MAX_REDIRECTS) {
                "Venera HTTP exceeded $VENERA_HTTP_MAX_REDIRECTS redirects"
            }
            val next = URL(target, location)
            require(next.protocol.equals("https", ignoreCase = true) ||
                next.protocol.equals("http", ignoreCase = true)
            ) {
                "Venera redirect URL must use HTTP(S)"
            }
            if (!sameVeneraOrigin(target, next)) {
                forwardHeaders.removeVeneraHeader("authorization")
                forwardHeaders.removeVeneraHeader("cookie")
            }
            if (result.status == 303 ||
                (result.status in setOf(301, 302) && method !in setOf("GET", "HEAD"))
            ) {
                method = "GET"
                bodyBytes = ByteArray(0)
                forwardHeaders.removeVeneraHeader("content-length")
                forwardHeaders.removeVeneraHeader("content-type")
                forwardHeaders.removeVeneraHeader("transfer-encoding")
            }
            target = next
        }
        error("Venera HTTP redirect state escaped its bounded loop")
    }

    private fun retainNativeBytes(bytes: ByteArray): String {
        val token = UUID.randomUUID().toString()
        synchronized(nativeBytes) {
            while (nativeBytes.size >= VENERA_MAX_NATIVE_BYTE_PAYLOADS) {
                nativeBytes.remove(nativeBytes.keys.first())
            }
            nativeBytes[token] = bytes
        }
        return token
    }

    fun takeNativeBytes(token: String): ByteArray? = synchronized(nativeBytes) {
        nativeBytes.remove(token)
    }

    private fun executeHttpRequest(
        target: URL,
        method: String,
        headers: Map<String, String>,
        bodyBytes: ByteArray,
        requestId: String?,
    ): VeneraHttpResponse {
        val result = resolverHttp.execute(
            target = target,
            method = method,
            headers = headers,
            bodyBytes = bodyBytes,
            requestId = requestId,
            maxResponseBytes = maxResponseBytes,
        )
        return veneraResponse(
            status = result.status,
            headers = result.headers,
            body = result.body,
        )
    }

    private fun persistResponseCookies(url: String, headers: JSONObject?) {
        if (!capabilities.contains("cookies") || headers == null) return
        headers.keys().asSequence()
            .filter { it.equals("set-cookie", ignoreCase = true) }
            .flatMap { headers.optString(it).split(Regex(",(?=[^;,]+=)" )).asSequence() }
            .map(String::trim)
            .filter(String::isNotEmpty)
            .forEach { cookieManager.setCookie(url, it) }
        cookieManager.flush()
    }

    private fun image(message: JSONObject): Any? {
        return when (message.getString("function")) {
            "decode" -> {
                val bytes = decodeWireValue(message.get("data")) as? ByteArray
                    ?: error("Venera image decode payload is invalid")
                val options = BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                    inMutable = true
                }
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                    ?: error("Venera image decode failed")
                requireImageSize(bitmap.width, bitmap.height)
                retainImage(bitmap)
            }
            "encode" -> {
                val bitmap = requireImage(message.getInt("key"))
                val output = java.io.ByteArrayOutputStream()
                require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                    "Venera image encode failed"
                }
                output.toByteArray().also {
                    require(it.size <= maxResponseBytes) {
                        "Venera transformed image exceeds runtime limit"
                    }
                }
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
            else -> error("unsupported Venera image operation")
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

    private fun cookie(message: JSONObject): Any? {
        requireCapability("cookies")
        val url = message.getString("url")
        return when (message.getString("function")) {
            "get" -> {
                AndroidBrowserCookieSession.importCookies(
                    appContext,
                    url,
                    expectedUserAgent = defaultUserAgent,
                )
                val raw = cookieManager.getCookie(url).orEmpty()
                JSONArray().apply {
                    raw.split(';').map(String::trim).filter(String::isNotEmpty).forEach { item ->
                        val separator = item.indexOf('=')
                        if (separator > 0) {
                            put(
                                JSONObject()
                                    .put("name", item.substring(0, separator))
                                    .put("value", item.substring(separator + 1))
                                    .put("domain", android.net.Uri.parse(url).host.orEmpty()),
                            )
                        }
                    }
                }
            }
            "set" -> {
                val rawCookies = message.opt("cookies")
                val cookies = when (rawCookies) {
                    is JSONArray -> rawCookies
                    is JSONObject -> JSONArray().apply {
                        rawCookies.keys().forEach { name ->
                            put(
                                JSONObject()
                                    .put("name", name)
                                    .put("value", rawCookies.optString(name)),
                            )
                        }
                    }
                    else -> JSONArray()
                }
                repeat(cookies.length()) { index ->
                    val cookie = cookies.getJSONObject(index)
                    val name = cookie.getString("name")
                    val cookieValue = cookie.getString("value")
                    require(name.isNotBlank() && !name.contains(Regex("[=;\r\n]"))) {
                        "Venera cookie name is invalid"
                    }
                    require(!cookieValue.contains(Regex("[\r\n]"))) {
                        "Venera cookie value is invalid"
                    }
                    val value = buildString {
                        append(name)
                        append('=')
                        append(cookieValue)
                        cookie.optString("domain").takeIf { it.isNotBlank() }?.let {
                            append("; Domain=")
                            append(it)
                        }
                        cookie.optString("path").takeIf { it.isNotBlank() }?.let {
                            append("; Path=")
                            append(it)
                        }
                        if (cookie.optBoolean("secure")) append("; Secure")
                        if (cookie.optBoolean("httpOnly")) append("; HttpOnly")
                    }
                    cookieManager.setCookie(url, value)
                }
                cookieManager.flush()
                null
            }
            "delete" -> {
                cookieManager.getCookie(url).orEmpty()
                    .split(';')
                    .map(String::trim)
                    .mapNotNull { it.substringBefore('=').takeIf(String::isNotBlank) }
                    .forEach { name -> cookieManager.setCookie(url, "$name=; Max-Age=0; Path=/") }
                cookieManager.flush()
                null
            }
            else -> error("unsupported Venera cookie operation")
        }
    }

    private fun isLogged(): Boolean {
        if (!capabilities.contains("persistentStorage")) return false
        val raw = preferences.getString("data:account", null) ?: return false
        return runCatching { !JSONObject(raw).isNull("value") }.getOrDefault(false)
    }

    private fun loadData(message: JSONObject): Any? {
        requireCapability("persistentStorage")
        val key = message.getString("data_key")
        val raw = preferences.getString("data:$key", null) ?: return null
        return JSONObject(raw).opt("value")
    }

    private fun saveData(message: JSONObject): Any? {
        requireCapability("persistentStorage")
        val key = message.getString("data_key")
        preferences.edit().putString(
            "data:$key",
            JSONObject().put("value", message.opt("data")).toString(),
        ).apply()
        return null
    }

    private fun deleteData(message: JSONObject): Any? {
        requireCapability("persistentStorage")
        preferences.edit().remove("data:${message.getString("data_key")}").apply()
        return null
    }

    private fun loadSetting(message: JSONObject): Any? {
        requireCapability("persistentStorage")
        val raw = preferences.getString(
            "setting:${message.getString("setting_key")}",
            null,
        ) ?: return null
        return runCatching {
            decodeWireValue(JSONObject(raw).opt("value"))
        }.getOrElse {
            // dev.58 stored setting values as plain strings. Preserve text,
            // while recovering booleans and string lists that otherwise have
            // different JavaScript truthiness/type semantics.
            when (raw.trim().lowercase(Locale.US)) {
                "true" -> true
                "false" -> false
                else -> runCatching {
                    val array = JSONArray(raw)
                    List(array.length()) { index -> array.optString(index) }
                }.getOrDefault(raw)
            }
        }
    }

    private fun saveSetting(message: JSONObject): Any? {
        requireCapability("persistentStorage")
        val key = message.getString("setting_key")
        val value = decodeWireValue(message.opt("value"))
        preferences.edit().putString(
            "setting:$key",
            JSONObject().put("value", encodeWireValue(value)).toString(),
        ).apply()
        return null
    }

    private fun convert(message: JSONObject): Any {
        val type = message.getString("type").lowercase(Locale.US)
        val encode = message.optBoolean("isEncode", true)
        val value = decodeWireValue(message.opt("value"))
        return when (type) {
            "utf8", "gbk" -> {
                val charset = if (type == "gbk") Charset.forName("GBK") else Charsets.UTF_8
                if (encode) value.toString().toByteArray(charset)
                else (value as ByteArray).toString(charset)
            }
            "base64" -> if (encode) {
                android.util.Base64.encodeToString(value as ByteArray, android.util.Base64.NO_WRAP)
            } else {
                android.util.Base64.decode(value.toString(), android.util.Base64.DEFAULT)
            }
            "md5", "sha1", "sha256", "sha512" -> {
                val algorithm = when (type) {
                    "md5" -> "MD5"
                    "sha1" -> "SHA-1"
                    "sha256" -> "SHA-256"
                    else -> "SHA-512"
                }
                MessageDigest.getInstance(algorithm).digest(value as ByteArray)
            }
            "hmac" -> {
                val hash = message.optString("hash", "sha256").lowercase(Locale.US)
                val algorithm = when (hash) {
                    "md5" -> "HmacMD5"
                    "sha1" -> "HmacSHA1"
                    "sha256" -> "HmacSHA256"
                    "sha512" -> "HmacSHA512"
                    else -> error("unsupported Venera HMAC hash")
                }
                val mac = Mac.getInstance(algorithm)
                mac.init(SecretKeySpec(decodeWireValue(message.get("key")) as ByteArray, algorithm))
                val output = mac.doFinal(value as ByteArray)
                if (message.optBoolean("isString")) {
                    output.joinToString("") { "%02x".format(it.toInt() and 0xff) }
                } else {
                    output
                }
            }
            "aes-ecb", "aes-cbc", "aes-cfb", "aes-ofb" -> {
                val mode = when (type) {
                    "aes-ecb" -> "ECB"
                    "aes-cbc" -> "CBC"
                    "aes-cfb" -> "CFB${message.optInt("blockSize", 128)}"
                    else -> "OFB${message.optInt("blockSize", 128)}"
                }
                val padding = if (type in setOf("aes-cfb", "aes-ofb")) "NoPadding" else "PKCS5Padding"
                val cipher = Cipher.getInstance("AES/$mode/$padding")
                val key = SecretKeySpec(decodeWireValue(message.get("key")) as ByteArray, "AES")
                val cipherMode = if (encode) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE
                if (type == "aes-ecb") {
                    cipher.init(cipherMode, key)
                } else {
                    val explicitIv = decodeWireValue(message.opt("iv")) as? ByteArray
                    val iv = explicitIv ?: ByteArray(cipher.blockSize)
                    cipher.init(cipherMode, key, IvParameterSpec(iv))
                }
                cipher.doFinal(value as ByteArray)
            }
            "rsa" -> {
                require(!encode) { "Venera RSA encryption is not exposed" }
                val keyBytes = decodeWireValue(message.get("key")) as ByteArray
                val keyFactory = KeyFactory.getInstance("RSA")
                val privateKey = runCatching {
                    keyFactory.generatePrivate(PKCS8EncodedKeySpec(keyBytes))
                }.getOrElse {
                    keyFactory.generatePublic(X509EncodedKeySpec(keyBytes))
                }
                val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
                cipher.init(Cipher.DECRYPT_MODE, privateKey)
                cipher.doFinal(value as ByteArray)
            }
            else -> error("unsupported Venera conversion")
        }
    }

    private fun random(message: JSONObject): Number {
        val min = message.optDouble("min", 0.0)
        val max = message.optDouble("max", 1.0)
        require(max >= min) { "invalid random range" }
        val value = min + Math.random() * (max - min)
        return if (message.optString("type") == "int") value.toInt() else value
    }

    private fun requireCapability(name: String) {
        require(capabilities.contains(name)) { "Venera capability denied: $name" }
    }

    companion object {
        private const val MAX_IMAGE_PIXELS = 32L * 1024L * 1024L
    }

    override fun close() {
        if (closed) return
        closed = true
        activationSink = null
        resultSink = null
        finishedSink = null
        asyncCalls.values.toList().forEach { requestId ->
            cancelled.add(requestId)
            resolverHttp.cancel(requestId)
        }
        asyncCalls.clear()
        cancelled.clear()
        synchronized(nativeBytes) { nativeBytes.clear() }
        releaseImages()
    }
}


private fun Any?.asVeneraCapabilities(): Set<String> {
    val values = this as? List<*> ?: error("capabilities must be a list")
    return values.filterIsInstance<String>().toSet()
}

private fun encodeWireValue(value: Any?): Any? = when (value) {
    null, JSONObject.NULL -> JSONObject.NULL
    is ByteArray -> JSONObject()
        .put("__zicType", "bytes")
        .put("base64", android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))
    is JSONObject, is JSONArray, is String, is Boolean, is Number -> value
    is Map<*, *> -> JSONObject(value)
    is Iterable<*> -> JSONArray(value.toList())
    else -> JSONObject.wrap(value)
}

private fun decodeWireValue(value: Any?): Any? = when (value) {
    null, JSONObject.NULL -> null
    is JSONObject -> {
        if (value.optString("__zicType") == "bytes") {
            android.util.Base64.decode(value.getString("base64"), android.util.Base64.DEFAULT)
        } else {
            value.keys().asSequence().associateWith { key -> decodeWireValue(value.opt(key)) }
        }
    }
    is JSONArray -> List(value.length()) { index -> decodeWireValue(value.opt(index)) }
    else -> value
}

internal fun normalizeVeneraAcceptEncoding(value: String?): String {
    val supported = value.orEmpty().split(',')
        .map { it.substringBefore(';').trim().lowercase(Locale.US) }
        .filter { it in setOf("gzip", "x-gzip", "deflate", "identity") }
        .map { if (it == "x-gzip") "gzip" else it }
        .distinct()
    return supported.filter { it != "identity" }.takeIf { it.isNotEmpty() }
        ?.joinToString(", ") ?: "gzip, deflate"
}

private fun JSONObject?.veneraControlHeader(name: String): String? =
    this?.keys()?.asSequence()?.firstOrNull {
        it.equals(name, ignoreCase = true)
    }?.let { key -> optString(key).trim().takeIf(String::isNotEmpty) }

private fun veneraRequestHeaders(
    raw: JSONObject?,
    defaultUserAgent: String,
): LinkedHashMap<String, String> {
    val headers = LinkedHashMap<String, String>()
    raw?.keys()?.forEach { name ->
        if (!name.equals("accept-encoding", ignoreCase = true) &&
            name.lowercase(Locale.US) !in VENERA_NETWORK_CONTROL_HEADERS
        ) {
            headers[name] = raw.optString(name)
        }
    }
    if (headers.keys.none { it.equals("user-agent", ignoreCase = true) } &&
        defaultUserAgent.isNotBlank()
    ) {
        headers["User-Agent"] = defaultUserAgent
    }
    val requestedEncoding = raw?.keys()?.asSequence()?.firstOrNull {
        it.equals("accept-encoding", ignoreCase = true)
    }?.let { name -> raw.optString(name) }
    headers["Accept-Encoding"] = normalizeVeneraAcceptEncoding(requestedEncoding)
    return headers
}

internal fun mergeVeneraCookieHeaders(
    explicit: String?,
    stored: String?,
): String? = listOf(explicit?.trim(), stored?.trim())
    .filter { !it.isNullOrEmpty() }
    .joinToString("; ")
    .takeIf(String::isNotEmpty)

internal data class VeneraHttpResponse(
    val status: Int,
    val headers: JSONObject,
    val body: ByteArray,
) {
    fun toWire(bytes: Boolean): JSONObject = JSONObject()
        .put("status", status)
        .put("headers", headers)
        .put(
            "body",
            if (bytes) encodeWireValue(body) else body.toString(Charsets.UTF_8),
        )
}

private fun veneraResponse(
    status: Int,
    headers: Map<*, *>,
    body: ByteArray,
): VeneraHttpResponse {
    val responseHeaders = JSONObject()
    headers.entries.forEach { (rawName, rawValues) ->
        val name = rawName as? String ?: return@forEach
        val values = when (rawValues) {
            is Iterable<*> -> rawValues.mapNotNull { it?.toString() }
            null -> emptyList()
            else -> listOf(rawValues.toString())
        }
        responseHeaders.put(name, values.joinToString(", "))
    }
    return VeneraHttpResponse(status, responseHeaders, body)
}

private fun JSONObject?.veneraHeaderValue(name: String): String? {
    if (this == null) return null
    val key = keys().asSequence().firstOrNull { it.equals(name, ignoreCase = true) }
        ?: return null
    return optString(key).takeIf { it.isNotBlank() }
}

private data class VeneraHttpCacheEntry(
    val requestHeaders: Map<String, String>,
    val response: VeneraHttpResponse,
    val storedAtNanos: Long,
    val size: Int,
)

internal data class VeneraHttpCacheNamespace(
    val pluginId: String,
    val pluginVersion: String,
    val sourceKey: String,
)

private data class VeneraHttpCacheKey(
    val namespace: VeneraHttpCacheNamespace,
    val url: String,
)

internal class VeneraHttpCacheStore {
    private val entries = LinkedHashMap<VeneraHttpCacheKey, VeneraHttpCacheEntry>()
    private var size = 0

    @Synchronized
    fun lookup(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        requestHeaders: Map<String, String>,
        cacheTime: String?,
        nowNanos: Long = System.nanoTime(),
        forceMiss: Boolean = false,
    ): VeneraHttpResponse? {
        val key = VeneraHttpCacheKey(namespace, url)
        if (forceMiss) {
            remove(key)
            return null
        }
        val entry = entries[key] ?: return null
        if (!veneraCacheHeadersMatch(requestHeaders, entry.requestHeaders)) {
            return null
        }
        if (cacheTime.equals("no", ignoreCase = true)) {
            remove(key)
            return null
        }
        val age = nowNanos - entry.storedAtNanos
        val fresh = if (cacheTime.equals("long", ignoreCase = true)) {
            age in 0 until VENERA_NETWORK_LONG_CACHE_NANOS
        } else {
            age in 0 until VENERA_NETWORK_SHORT_CACHE_NANOS
        }
        if (!fresh) return null
        entries.remove(key)
        entries[key] = entry
        return entry.response.withVeneraCacheHit()
    }

    @Synchronized
    fun store(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        requestHeaders: Map<String, String>,
        response: VeneraHttpResponse,
        nowNanos: Long = System.nanoTime(),
    ) {
        if (response.status >= 400 ||
            response.body.isEmpty() ||
            response.body.size >= VENERA_NETWORK_MAX_CACHE_ENTRY_BYTES
        ) {
            return
        }
        val key = VeneraHttpCacheKey(namespace, url)
        remove(key)
        while (entries.isNotEmpty() &&
            size + response.body.size > VENERA_NETWORK_MAX_CACHE_BYTES
        ) {
            remove(entries.keys.first())
        }
        if (response.body.size > VENERA_NETWORK_MAX_CACHE_BYTES) return
        entries[key] = VeneraHttpCacheEntry(
            requestHeaders = LinkedHashMap(requestHeaders),
            response = response.copy(
                headers = JSONObject(response.headers.toString()),
                body = response.body.copyOf(),
            ),
            storedAtNanos = nowNanos,
            size = response.body.size,
        )
        size += response.body.size
    }

    @Synchronized
    fun invalidate(namespace: VeneraHttpCacheNamespace, url: String) {
        remove(VeneraHttpCacheKey(namespace, url))
    }

    @Synchronized
    fun clear() {
        entries.clear()
        size = 0
    }

    private fun remove(key: VeneraHttpCacheKey) {
        entries.remove(key)?.let { size -= it.size }
    }
}

internal fun veneraCacheHeadersMatch(
    first: Map<String, String>,
    second: Map<String, String>,
): Boolean = veneraComparableCacheHeaders(first) ==
    veneraComparableCacheHeaders(second)

private fun veneraComparableCacheHeaders(
    headers: Map<String, String>,
): Map<String, String> = headers.entries
    .filterNot { it.key.lowercase(Locale.US) in VENERA_CACHE_IGNORED_HEADERS }
    .associate { it.key.lowercase(Locale.US) to it.value }

private fun VeneraHttpResponse.withVeneraCacheHit(): VeneraHttpResponse {
    val cacheHeaders = JSONObject(headers.toString())
    cacheHeaders.put("venera-cache", "true")
    return copy(headers = cacheHeaders, body = body.copyOf())
}

private fun MutableMap<String, String>.removeVeneraHeader(name: String) {
    keys.filter { it.equals(name, ignoreCase = true) }
        .forEach { remove(it) }
}

private fun sameVeneraOrigin(first: URL, second: URL): Boolean =
    first.protocol.equals(second.protocol, ignoreCase = true) &&
        first.host.equals(second.host, ignoreCase = true) &&
        first.veneraEffectivePort() == second.veneraEffectivePort()

private fun URL.veneraEffectivePort(): Int = when {
    port >= 0 -> port
    defaultPort >= 0 -> defaultPort
    protocol.equals("https", ignoreCase = true) -> 443
    else -> 80
}

private fun hasVeneraEncodedImageSignature(bytes: ByteArray): Boolean {
    fun matches(offset: Int, vararg signature: Int): Boolean {
        if (offset < 0 || offset + signature.size > bytes.size) return false
        return signature.indices.all { index ->
            (bytes[offset + index].toInt() and 0xff) == signature[index]
        }
    }

    fun ascii(offset: Int, value: String): Boolean {
        if (offset < 0 || offset + value.length > bytes.size) return false
        return value.indices.all { index ->
            (bytes[offset + index].toInt() and 0xff) == value[index].code
        }
    }

    if (matches(0, 0xff, 0xd8, 0xff)) return true
    if (matches(0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return true
    if (ascii(0, "RIFF") && ascii(8, "WEBP")) return true
    if (ascii(0, "GIF87a") || ascii(0, "GIF89a")) return true
    if (matches(0, 0x42, 0x4d)) return true
    if (matches(0, 0x49, 0x49, 0x2a, 0x00) || matches(0, 0x4d, 0x4d, 0x00, 0x2a)) {
        return true
    }
    if (matches(0, 0x00, 0x00, 0x01, 0x00)) return true
    if (ascii(4, "ftyp") && bytes.size >= 12) {
        val brands = LinkedHashSet<String>()
        fun brandAt(offset: Int): String = buildString(4) {
            for (index in offset until offset + 4) {
                append((bytes[index].toInt() and 0xff).toChar().lowercaseChar())
            }
        }
        brands.add(brandAt(8))
        var offset = 16
        while (offset + 4 <= minOf(bytes.size, 64)) {
            brands.add(brandAt(offset))
            offset += 4
        }
        if (brands.any { it == "avif" || it == "avis" }) return true
        if (brands.any {
                it in setOf("heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1")
            }
        ) {
            return true
        }
    }
    return false
}

private const val VENERA_HTTP_MAX_REDIRECTS = 8
private const val VENERA_HTTP_MAX_REQUEST_BYTES = 2 * 1024 * 1024
private const val VENERA_MAX_NATIVE_BYTE_PAYLOADS = 2
private const val VENERA_NETWORK_MAX_CACHE_BYTES = 10 * 1024 * 1024
private const val VENERA_NETWORK_MAX_CACHE_ENTRY_BYTES = 1024 * 1024
private const val VENERA_NETWORK_SHORT_CACHE_NANOS = 5L * 1_000_000_000L
private const val VENERA_NETWORK_LONG_CACHE_NANOS = 6L * 60L * 60L * 1_000_000_000L
private val VENERA_NETWORK_CONTROL_HEADERS = setOf("cache-time", "prevent-parallel")
private val VENERA_CACHE_IGNORED_HEADERS = setOf(
    "cache-time",
    "prevent-parallel",
    "date",
    "x-varnish",
    "cf-ray",
    "connection",
    "vary",
    "content-encoding",
    "report-to",
    "server-timing",
    "token",
    "set-cookie",
    "cf-cache-status",
    "cf-request-id",
    "authorization",
)
private val VENERA_HTTP_REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)

private fun verifyVeneraPayload(file: File, expectedLength: Long, expectedSha256: String) {
    require(file.isFile) { "Venera payload is missing" }
    require(file.length() == expectedLength) { "Venera payload length changed" }
    val actual = MessageDigest.getInstance("SHA-256").digest(file.readBytes())
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    require(actual.equals(expectedSha256, ignoreCase = true)) { "Venera payload digest changed" }
}

private fun String.jsQuoted(): String = JSONObject.quote(this)

private const val VENERA_BOOTSTRAP = """
// Venera source files are ordinary scripts. Do not force strict mode over the
// appended source: several ecosystem scripts rely on legacy global scratch
// bindings. Predeclare `res` as a configurable global so strict class methods
// that assign it retain the behavior of the official host.
if (!Object.prototype.hasOwnProperty.call(globalThis, 'res')) Object.defineProperty(globalThis, 'res', {value:undefined,writable:true,configurable:true});
const appVersion = '1.6.0';
function __zicErrorMessage(error,operation){const message=String(error?.message||error);const stack=String(error?.stack||'').split('\n').slice(1,5).map(v=>v.trim()).filter(Boolean).join(' | ');const prefix=operation?String(operation)+': ':'';return (prefix+message+(stack?' ['+stack+']':'')).slice(0,900)}
function __zicCompareVersion(a,b){const x=String(a).split(/[^0-9]+/).filter(Boolean).map(Number),y=String(b).split(/[^0-9]+/).filter(Boolean).map(Number);for(let i=0;i<Math.max(x.length,y.length);i++){const d=(x[i]||0)-(y[i]||0);if(d)return d>0?1:-1}return 0}
const __zicCancelled = new Set();
const __zicResources = new Map();
const __zicResourceLimit = 2048;
const __zicResourceConfigs = new Map();
const __zicResourceResolutions = new Map();
const __zicPaging = new Map();
let __zicResourceKey = 0;
function __zicRetainResource(config){const token=String(++__zicResourceKey);__zicResources.set(token,config);while(__zicResources.size>__zicResourceLimit)__zicResources.delete(__zicResources.keys().next().value);return token}
function __zicGetResource(token){const config=__zicResources.get(token);if(config){__zicResources.delete(token);__zicResources.set(token,config)}return config}
function __zicRememberResourceConfig(uri,config){__zicResourceConfigs.delete(uri);__zicResourceConfigs.set(uri,config);while(__zicResourceConfigs.size>__zicResourceLimit)__zicResourceConfigs.delete(__zicResourceConfigs.keys().next().value);return config}
const __zicSemanticRetryLimit=5;
function __zicResourceUri(config){const uri='venera-resource:'+__zicB64({v:1,image:String(config.image),comicId:config.comicId??null,epId:config.epId??null});__zicRememberResourceConfig(uri,config);return uri}
function __zicResourceIdentity(uri){const key=String(uri),payload=key.slice('venera-resource:'.length);if(payload.startsWith('//'))return __zicGetResource(payload.slice(2));try{const value=__zicUnb64(payload);if(value?.v!==1||typeof value.image!=='string')return undefined;return {image:value.image,comicId:value.comicId??null,epId:value.epId??null,deferredImageConfig:true}}catch(_){return __zicGetResource(payload)}}
function __zicResolveResourceUri(uri){const key=String(uri),retained=__zicResourceConfigs.get(key);if(retained){__zicRememberResourceConfig(key,retained);return retained}const identity=__zicResourceIdentity(key);return identity?__zicRememberResourceConfig(key,identity):undefined}
async function __zicBuildResourceConfig(key,identity,source){const original=identity.image;const override=await Promise.resolve(source.comic?.onImageLoad?.(original,identity.comicId,identity.epId)||{});return __zicRememberResourceConfig(key,{url:override.url||original,method:override.method||'GET',headers:override.headers||{},data:override.data,onResponse:override.onResponse,onLoadFailed:override.onLoadFailed,modifyImage:override.modifyImage,__zicSemanticRetryCount:0})}
async function __zicResolveResourceConfig(uri,source){const key=String(uri),retained=__zicResolveResourceUri(key);if(!retained)throw new Error('Venera resource locator is unavailable');if(!retained.deferredImageConfig)return retained;const pending=__zicResourceResolutions.get(key);if(pending)return pending;const resolution=__zicBuildResourceConfig(key,retained,source);__zicResourceResolutions.set(key,resolution);try{return await resolution}finally{if(__zicResourceResolutions.get(key)===resolution)__zicResourceResolutions.delete(key)}}
async function __zicResolveHttpArtworkConfig(uri,source){const key=String(uri),baseKey=key.split('@',1)[0],retained=__zicResourceConfigs.get(key);if(retained){__zicRememberResourceConfig(key,retained);return retained}const pending=__zicResourceResolutions.get(key);if(pending)return pending;const resolution=(async()=>{let override={};if(typeof source.comic?.onThumbnailLoad==='function'){try{override=await Promise.resolve(source.comic.onThumbnailLoad(baseKey))||{}}catch(_){override={}}}else if(typeof source.comic?.onImageLoad==='function'){try{override=await Promise.resolve(source.comic.onImageLoad(baseKey,null,null))||{}}catch(_){override={}}}return __zicRememberResourceConfig(key,{url:override.url||baseKey,method:override.method||'GET',headers:override.headers||{},data:override.data,onResponse:override.onResponse,onLoadFailed:override.onLoadFailed,modifyImage:override.modifyImage,__zicSemanticRetryCount:0})})();__zicResourceResolutions.set(key,resolution);try{return await resolution}finally{if(__zicResourceResolutions.get(key)===resolution)__zicResourceResolutions.delete(key)}}
function __zicDescribeResourceRequest(config){const method=String(config.method||'GET').toUpperCase(),headers={...(config.headers||{})};if(!Object.keys(headers).some(key=>String(key).toLowerCase()==='accept-encoding'))headers['Accept-Encoding']='identity';if(!Object.keys(headers).some(key=>String(key).toLowerCase()==='cookie')){try{const cookies=Network.getCookies(String(config.url||''))||[];if(Array.isArray(cookies)&&cookies.length)headers.Cookie=cookies.map(cookie=>String(cookie.name)+'='+String(cookie.value)).join('; ')}catch(_){}}const requiresRuntimeTransform=typeof config.onResponse==='function'||(typeof config.modifyImage==='string'&&config.modifyImage.trim().length>0);return {url:String(config.url||''),method,headers,body:__zicNetworkPayload(method,config.data),requiresRuntimeTransform}}
async function __zicRetryResourceConfig(uri,source){const key=String(uri);let active=__zicResourceConfigs.get(key);if(!active&&key.startsWith('venera-resource:'))active=await __zicResolveResourceConfig(key,source);const retryCount=Math.max(0,Number(active?.__zicSemanticRetryCount||0));if(!active||retryCount>=__zicSemanticRetryLimit||typeof active.onLoadFailed!=='function')return {available:false};const retry=await Promise.resolve(active.onLoadFailed());if(!retry)return {available:false};active=__zicRememberResourceConfig(key,{url:retry.url||active.url,method:retry.method||'GET',headers:retry.headers||{},data:retry.data,onResponse:retry.onResponse,onLoadFailed:retry.onLoadFailed,modifyImage:retry.modifyImage,__zicSemanticRetryCount:retryCount+1});return {available:true,request:__zicDescribeResourceRequest(active)}}
function __zicHasEncodedImageSignature(value){const b=value instanceof ArrayBuffer?new Uint8Array(value):ArrayBuffer.isView(value)?new Uint8Array(value.buffer,value.byteOffset,value.byteLength):null;if(!b)return false;const m=(o,a)=>o>=0&&o+a.length<=b.length&&a.every((v,i)=>b[o+i]===v),s=(o,v)=>o>=0&&o+v.length<=b.length&&Array.from(v).every((c,i)=>b[o+i]===c.charCodeAt(0));if(m(0,[255,216,255])||m(0,[137,80,78,71,13,10,26,10])||(s(0,'RIFF')&&s(8,'WEBP'))||s(0,'GIF87a')||s(0,'GIF89a')||m(0,[66,77])||m(0,[73,73,42,0])||m(0,[77,77,0,42])||m(0,[0,0,1,0]))return true;if(s(4,'ftyp')&&b.length>=12){const four=o=>String.fromCharCode(...b.subarray(o,o+4)).toLowerCase(),brands=new Set([four(8)]);for(let o=16;o+4<=Math.min(b.length,64);o+=4)brands.add(four(o));for(const x of ['avif','avis','heic','heix','hevc','hevx','heim','heis','mif1','msf1'])if(brands.has(x))return true}return false}
function __zicDecode(value) {
  if (value && value.__zicType === 'bytes') {
    const raw = atob(value.base64); const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes.buffer;
  }
  if (Array.isArray(value)) return value.map(__zicDecode);
  if (value && typeof value === 'object') {
    const out = {}; for (const [k,v] of Object.entries(value)) out[k] = __zicDecode(v); return out;
  }
  return value;
}
function __zicEncode(value) {
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) {
    const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    let raw = ''; for (let i=0;i<bytes.length;i+=0x8000) raw += String.fromCharCode(...bytes.subarray(i,i+0x8000));
    return {__zicType:'bytes', base64:btoa(raw)};
  }
  if (Array.isArray(value)) return value.map(__zicEncode);
  if (value && typeof value === 'object') {
    const out = {}; for (const [k,v] of Object.entries(value)) {
      if (typeof v !== 'function') out[k] = __zicEncode(v);
    } return out;
  }
  return value;
}
let __zicActiveRequestId=null;
let __zicFreshResolverDepth=0;
const __zicBridgeMetrics=new Map();
const __zicBridgeWaiters=new Map();
let __zicBridgeCallKey=0;
const __zicActivationWork=new Set();
let __zicActivationOpen=true;
function __zicNowMicros(){const clock=globalThis.performance?.now?.bind(globalThis.performance);return Math.round((clock?clock():Date.now())*1000)}
function __zicBridgeMetric(requestId){if(!requestId)return {networkMicros:0,networkCalls:0,networkCacheHits:0,networkOriginCalls:0};let metric=__zicBridgeMetrics.get(requestId);if(!metric){metric={networkMicros:0,networkCalls:0,networkCacheHits:0,networkOriginCalls:0};__zicBridgeMetrics.set(requestId,metric)}return metric}
function __zicBridgeNetworkSnapshot(requestId){const metric=requestId?__zicBridgeMetrics.get(requestId):null;return {networkMicros:Number(metric?.networkMicros||0),networkCalls:Number(metric?.networkCalls||0),networkCacheHits:Number(metric?.networkCacheHits||0),networkOriginCalls:Number(metric?.networkOriginCalls||0)}}
function __zicBridgeCacheHit(value){const headers=value?.headers;if(!headers||typeof headers!=='object')return false;for(const [name,raw] of Object.entries(headers)){if(String(name).toLowerCase()==='venera-cache'&&String(raw).toLowerCase()==='true')return true}return false}
const __zicBrowserSetTimeout=globalThis.setTimeout.bind(globalThis);
const __zicBrowserClearTimeout=globalThis.clearTimeout.bind(globalThis);
const __zicDelayWaiters=new Map();
function __zicDelay(time,requestId){
  const duration=Math.max(0,Math.min(30000,Number(time)||0));
  return new Promise((resolve,reject)=>{
    const waiter={timer:null,reject};
    const remove=()=>{if(!requestId)return;const scoped=__zicDelayWaiters.get(requestId);if(!scoped)return;scoped.delete(waiter);if(scoped.size===0)__zicDelayWaiters.delete(requestId)};
    waiter.timer=__zicBrowserSetTimeout(()=>{remove();if(requestId&&__zicCancelled.has(requestId)){reject(new Error('Venera request was cancelled'));return}resolve(null)},duration);
    if(requestId){let scoped=__zicDelayWaiters.get(requestId);if(!scoped){scoped=new Set();__zicDelayWaiters.set(requestId,scoped)}scoped.add(waiter)}
  });
}
function __zicCancelDelays(requestId){const scoped=__zicDelayWaiters.get(requestId);if(!scoped)return;__zicDelayWaiters.delete(requestId);for(const waiter of scoped){__zicBrowserClearTimeout(waiter.timer);waiter.reject(new Error('Venera request was cancelled'))}}
function __zicTrackActivationWork(promise){if(!__zicActivationOpen)return promise;let tracked;const settle=(value,error)=>new Promise((resolve,reject)=>{__zicBrowserSetTimeout(()=>{__zicActivationWork.delete(tracked);if(error)reject(error);else resolve(value)},0)});tracked=Promise.resolve(promise).then(value=>settle(value),error=>settle(null,error));__zicActivationWork.add(tracked);return tracked}
async function __zicWaitForActivationWork(){while(__zicActivationWork.size)await Promise.allSettled(Array.from(__zicActivationWork))}
function __zicBridgeResponse(callId,raw){const key=String(callId),waiter=__zicBridgeWaiters.get(key);if(!waiter)return;__zicBridgeWaiters.delete(key);try{const envelope=typeof raw==='string'?JSON.parse(raw):raw;if(!envelope?.ok){waiter.reject(new Error(envelope?.error||'Venera bridge failed'));return}waiter.resolve(__zicDecode(envelope.value))}catch(error){waiter.reject(error)}}
function __zicRequestAsync(message){const callId='zic-async-'+String(++__zicBridgeCallKey);const request={...message,bridgeCallId:callId};return new Promise((resolve,reject)=>{__zicBridgeWaiters.set(callId,{resolve,reject});try{ZicNative.requestAsync(JSON.stringify(__zicEncode(request)))}catch(error){__zicBridgeWaiters.delete(callId);reject(error)}})}
function sendMessage(message) {
  const requestId=message.requestId??__zicActiveRequestId;
  if(requestId&&message.requestId==null){message={...message,requestId}}
  if(requestId&&__zicCancelled.has(requestId)){
    const error=new Error('Venera request was cancelled');
    if(message.method==='delay')return Promise.reject(error);
    throw error;
  }
  if(message.method==='delay')return __zicDelay(message.time,requestId);
  const networkCall=message.method==='http'||message.method==='http_binary'||message.method==='http_image_binary';
  if(networkCall&&__zicFreshResolverDepth>0&&message.__zicFreshResolver!==true){message={...message,__zicFreshResolver:true}}
  if(networkCall&&typeof ZicNative.requestAsync==='function'){
    const networkStarted=__zicNowMicros();
    const asyncResult=__zicRequestAsync(message).then(value=>{if(requestId){const metric=__zicBridgeMetric(requestId);metric.networkMicros+=Math.max(0,__zicNowMicros()-networkStarted);metric.networkCalls++;if(__zicBridgeCacheHit(value))metric.networkCacheHits++;else metric.networkOriginCalls++}return value},error=>{if(requestId){const metric=__zicBridgeMetric(requestId);metric.networkMicros+=Math.max(0,__zicNowMicros()-networkStarted);metric.networkCalls++;metric.networkOriginCalls++}throw error});
    return __zicTrackActivationWork(asyncResult);
  }
  const networkStarted=networkCall?__zicNowMicros():0;
  let decodedValue;
  try {
    const envelope = JSON.parse(ZicNative.request(JSON.stringify(__zicEncode(message))));
    if (!envelope.ok) throw new Error(envelope.error || 'Venera bridge failed');
    decodedValue=__zicDecode(envelope.value);
    return decodedValue;
  } finally {
    if(networkCall&&requestId){const metric=__zicBridgeMetric(requestId);metric.networkMicros+=Math.max(0,__zicNowMicros()-networkStarted);metric.networkCalls++;if(__zicBridgeCacheHit(decodedValue))metric.networkCacheHits++;else metric.networkOriginCalls++}
  }
}
function Cookie({name,value,domain}) { this.name=name; this.value=value; this.domain=domain; }
const Convert = {
  encodeUtf8:v=>sendMessage({method:'convert',type:'utf8',value:v,isEncode:true}),
  decodeUtf8:v=>sendMessage({method:'convert',type:'utf8',value:v,isEncode:false}),
  encodeGbk:v=>sendMessage({method:'convert',type:'gbk',value:v,isEncode:true}),
  decodeGbk:v=>sendMessage({method:'convert',type:'gbk',value:v,isEncode:false}),
  encodeBase64:v=>sendMessage({method:'convert',type:'base64',value:v,isEncode:true}),
  decodeBase64:v=>sendMessage({method:'convert',type:'base64',value:v,isEncode:false}),
  md5:v=>sendMessage({method:'convert',type:'md5',value:v,isEncode:true}),
  sha1:v=>sendMessage({method:'convert',type:'sha1',value:v,isEncode:true}),
  sha256:v=>sendMessage({method:'convert',type:'sha256',value:v,isEncode:true}),
  sha512:v=>sendMessage({method:'convert',type:'sha512',value:v,isEncode:true}),
  hmac:(key,value,hash)=>sendMessage({method:'convert',type:'hmac',key,value,hash,isEncode:true}),
  hmacString:(key,value,hash)=>sendMessage({method:'convert',type:'hmac',key,value,hash,isEncode:true,isString:true}),
  encryptAesEcb:(value,key)=>sendMessage({method:'convert',type:'aes-ecb',value,key,isEncode:true}),
  decryptAesEcb:(value,key)=>sendMessage({method:'convert',type:'aes-ecb',value,key,isEncode:false}),
  encryptAesCbc:(value,key,iv)=>sendMessage({method:'convert',type:'aes-cbc',value,key,iv,isEncode:true}),
  decryptAesCbc:(value,key,iv)=>sendMessage({method:'convert',type:'aes-cbc',value,key,iv,isEncode:false}),
  encryptAesCfb:(value,key,iv,blockSize)=>sendMessage({method:'convert',type:'aes-cfb',value,key,iv,blockSize,isEncode:true}),
  decryptAesCfb:(value,key,iv,blockSize)=>sendMessage({method:'convert',type:'aes-cfb',value,key,iv,blockSize,isEncode:false}),
  encryptAesOfb:(value,key,blockSize)=>sendMessage({method:'convert',type:'aes-ofb',value,key,blockSize,isEncode:true}),
  decryptAesOfb:(value,key,blockSize)=>sendMessage({method:'convert',type:'aes-ofb',value,key,blockSize,isEncode:false}),
  decryptRsa:(value,key)=>sendMessage({method:'convert',type:'rsa',value,key,isEncode:false}),
  hexEncode:(value)=>Array.from(new Uint8Array(value)).map(v=>v.toString(16).padStart(2,'0')).join(''),
};
function createUuid(){ return sendMessage({method:'uuid'}); }
function randomInt(min,max){ return sendMessage({method:'random',type:'int',min,max}); }
function randomDouble(min,max){ return sendMessage({method:'random',type:'double',min,max}); }
function __zicNetworkPayload(method,data){return /^(GET|HEAD)$/i.test(String(method||'GET'))?undefined:data}
const Network = {
  fetchBytes:async(method,url,headers,data,extra)=>sendMessage({method:'http',http_method:method,bytes:true,url,headers:headers||{},data:__zicNetworkPayload(method,data),extra}),
  fetchBinary:async(method,url,headers,data)=>sendMessage({method:'http_binary',http_method:method,url,headers:headers||{},data:__zicNetworkPayload(method,data)}),
  sendRequest:async(method,url,headers,data,extra)=>sendMessage({method:'http',http_method:method,url,headers:headers||{},data:__zicNetworkPayload(method,data),extra}),
  get(url,headers,extra){return this.sendRequest('GET',url,headers,undefined,extra)}, post(url,headers,data,extra){return this.sendRequest('POST',url,headers,data,extra)},
  put(url,headers,data,extra){return this.sendRequest('PUT',url,headers,data,extra)}, patch(url,headers,data,extra){return this.sendRequest('PATCH',url,headers,data,extra)},
  delete(url,headers,extra){return this.sendRequest('DELETE',url,headers,undefined,extra)},
  setCookies(url,cookies){return sendMessage({method:'cookie',function:'set',url,cookies})},
  getCookies(url){return sendMessage({method:'cookie',function:'get',url})},
  deleteCookies(url){return sendMessage({method:'cookie',function:'delete',url})},
};
// Host-private image-body fast path: public Network.fetchBinary remains a
// general binary API, while final image loading can reject 2xx HTML/error
// bodies before native-token publication and re-enter source onLoadFailed.
async function __zicFetchImageBinary(method,url,headers,data){return sendMessage({method:'http_image_binary',http_method:method,url,headers:headers||{},data:__zicNetworkPayload(method,data)})}
async function fetch(url,options={}) {
  const result=await Network.fetchBytes(options.method||'GET',url,options.headers||{},options.body);
  return {ok:result.status>=200&&result.status<300,status:result.status,statusText:'',headers:result.headers,
    arrayBuffer:async()=>result.body,text:async()=>Convert.decodeUtf8(result.body),json:async()=>JSON.parse(Convert.decodeUtf8(result.body))};
}
class HtmlDocument {
  constructor(html){this.document=new DOMParser().parseFromString(html,'text/html')}
  querySelector(q){const e=this.document.querySelector(q);return e?new HtmlElement(e):null}
  querySelectorAll(q){return Array.from(this.document.querySelectorAll(q)).map(e=>new HtmlElement(e))}
  getElementById(id){const e=this.document.getElementById(id);return e?new HtmlElement(e):null}
  dispose(){this.document=null}
}
class HtmlElement {
  constructor(element){this.element=element}
  get text(){return this.element.textContent||''}
  get attributes(){const out={};for(const a of this.element.attributes||[])out[a.name]=a.value;return out}
  querySelector(q){const e=this.element.querySelector(q);return e?new HtmlElement(e):null}
  querySelectorAll(q){return Array.from(this.element.querySelectorAll(q)).map(e=>new HtmlElement(e))}
  get children(){return Array.from(this.element.children||[]).map(e=>new HtmlElement(e))}
  get nodes(){return Array.from(this.element.childNodes||[]).map(e=>new HtmlNode(e))}
  get innerHTML(){return this.element.innerHTML||''} get parent(){return this.element.parentElement?new HtmlElement(this.element.parentElement):null}
  get classNames(){return Array.from(this.element.classList||[])} get id(){return this.element.id||null} get localName(){return this.element.localName||''}
  get previousElementSibling(){return this.element.previousElementSibling?new HtmlElement(this.element.previousElementSibling):null}
  get nextElementSibling(){return this.element.nextElementSibling?new HtmlElement(this.element.nextElementSibling):null}
}
class HtmlNode { constructor(node){this.node=node} get text(){return this.node.textContent||''} get type(){return this.node.nodeType===1?'element':this.node.nodeType===3?'text':this.node.nodeType===8?'comment':'unknown'} toElement(){return this.node.nodeType===1?new HtmlElement(this.node):null} }
function Comic(v){Object.assign(this,v);this.subtitle=this.subtitle??this.subTitle}
function ComicDetails(v){Object.assign(this,v);this.subtitle=this.subtitle??this.subTitle}
function Comment(v){Object.assign(this,v)} function ImageLoadingConfig(v){Object.assign(this,v)}
class Image {
  constructor(key){this.key=key}
  copyRange(x,y,width,height){const key=sendMessage({method:'image',function:'copyRange',key:this.key,x,y,width,height});return key==null?null:new Image(key)}
  copyAndRotate90(){const key=sendMessage({method:'image',function:'copyAndRotate90',key:this.key});return key==null?null:new Image(key)}
  fillImageAt(x,y,image){sendMessage({method:'image',function:'fillImageAt',key:this.key,x,y,image:image.key})}
  fillImageRangeAt(x,y,image,srcX,srcY,width,height){sendMessage({method:'image',function:'fillImageRangeAt',key:this.key,x,y,image:image.key,srcX,srcY,width,height})}
  get width(){return sendMessage({method:'image',function:'getWidth',key:this.key})}
  get height(){return sendMessage({method:'image',function:'getHeight',key:this.key})}
  static empty(width,height){return new Image(sendMessage({method:'image',function:'emptyImage',width,height}))}
}
class ComicSource {
  name='';key='';version='';minAppVersion='';url='';translation={};static sources={};init(){}
  loadData(dataKey){return sendMessage({method:'load_data',key:this.key,data_key:dataKey})}
  saveData(dataKey,data){return sendMessage({method:'save_data',key:this.key,data_key:dataKey,data})}
  deleteData(dataKey){return sendMessage({method:'delete_data',key:this.key,data_key:dataKey})}
  loadSetting(key){const stored=sendMessage({method:'load_setting',key:this.key,setting_key:key});if(stored!==null&&stored!==undefined)return stored;const setting=this.settings?.[key];if(setting===null||setting===undefined)return null;if(typeof setting!=='object')return setting;if(setting.default!==undefined)return setting.default;const first=setting.options?.[0];return first&&typeof first==='object'?(first.value??first.key??null):(first??null)}
  saveSetting(key,value){return sendMessage({method:'save_setting',key:this.key,setting_key:key,value})}
  get isLogged(){return sendMessage({method:'isLogged',key:this.key})}
  translate(key){return this.translation?.[APP.locale]?.[key]??key}
}
const APP={get version(){return appVersion},get locale(){return sendMessage({method:'getLocale'})},get platform(){return 'android'}};

function __zicInstallSourceData(source){
 const proxy=new Proxy({}, {get:(_,key)=>source.loadData(String(key)),set:(_,key,value)=>{source.saveData(String(key),value);return true},deleteProperty:(_,key)=>{source.deleteData(String(key));return true},has:(_,key)=>source.loadData(String(key))!==null});
 try{Object.defineProperty(source,'data',{value:proxy,writable:false,configurable:true})}catch(_){try{source.data=proxy}catch(__){}}
}
function __zicAccountDescriptor(source){const account=source?.account;if(!account||typeof account!=='object')return {loggedIn:Boolean(source?.isLogged),supportsCredentials:false,cookieFields:[],loginWebsite:null,registerWebsite:null};const cookies=account.loginWithCookies,web=account.loginWithWebview;return {loggedIn:Boolean(source.isLogged),supportsCredentials:typeof account.login==='function',cookieFields:Array.isArray(cookies?.fields)?cookies.fields.map(field=>String(field?.key??field?.name??field?.title??field)).filter(Boolean):[],loginWebsite:web?.url?String(web.url):null,registerWebsite:account.registerWebsite??source.registerWebsite??null}}
async function __zicLoginSource(source,mode,values){const account=source?.account;if(!account||typeof account!=='object')throw new Error('Venera source exposes no account login');
 if(mode==='credentials'){if(typeof account.login!=='function')throw new Error('Venera source exposes no credential login');const name=String(values?.account??''),password=String(values?.password??'');if(!name||!password)throw new Error('Account and password are required');const result=await Promise.resolve(account.login.call(source,name,password));if(result===false)throw new Error('Venera credential login was rejected');source.saveData('account',[name,password]);return null}
 if(mode==='cookies'){const config=account.loginWithCookies;if(!config||typeof config.validate!=='function')throw new Error('Venera source exposes no cookie login');const raw=values?.cookies&&typeof values.cookies==='object'?values.cookies:{};const fields=Array.isArray(config.fields)?config.fields.map(field=>String(field?.key??field?.name??field?.title??field)):Object.keys(raw);const ordered=fields.map(field=>String(raw[field]??''));const result=await Promise.resolve(config.validate.call(source,ordered));if(result===false)throw new Error('Venera cookie login was rejected');source.saveData('account','ok');return null}
 if(mode==='web'){const config=account.loginWithWebview;if(!config)throw new Error('Venera source exposes no web login');const currentUrl=String(values?.currentUrl??config.url??''),title=String(values?.title??'');const imported=values?.cookies&&typeof values.cookies==='object'?values.cookies:{};const localStorage=values?.localStorage&&typeof values.localStorage==='object'?values.localStorage:{};if(currentUrl&&Object.keys(imported).length)Network.setCookies(currentUrl,imported);if(typeof config.checkStatus==='function'){const ok=await Promise.resolve(config.checkStatus.call(source,currentUrl,title));if(!ok)throw new Error('Venera web login is not complete')}if(Object.keys(localStorage).length)source.saveData('_localStorage',localStorage);if(typeof config.onLoginSuccess==='function')await Promise.resolve(config.onLoginSuccess.call(source));source.saveData('account','ok');return null}
 throw new Error('Unsupported Venera login mode: '+String(mode));
}
async function __zicLogoutSource(source){const account=source?.account;if(typeof account?.logout==='function')await Promise.resolve(account.logout.call(source));source.deleteData('account');return null}
function __zicTranslateSetting(source,value){const text=String(value??'');try{return typeof source?.translate==='function'?String(source.translate(text)):text}catch(_){return text}}
function __zicSettingChoices(source,setting){const values=Array.isArray(setting?.options)?setting.options:[];return values.map(option=>{if(option&&typeof option==='object'){const value=String(option.value??option.key??option.id??'');const label=__zicTranslateSetting(source,option.text??option.label??option.title??value);return{value,label}}const raw=String(option??''),split=raw.indexOf('-');const value=split<0?raw:raw.slice(0,split),label=split<0?raw:raw.slice(split+1);return{value,label:__zicTranslateSetting(source,label)}}).filter(choice=>choice.value!=='')}
function __zicSettingSensitive(key,setting){if(setting?.sensitive===true||setting?.obscure===true)return true;return /password|passwd|token|cookie|secret|api.?key|密码|令牌/i.test(String(key)+' '+String(setting?.title??''))}
function __zicSourceSettings(source){const settings=source?.settings;if(!settings||typeof settings!=='object')return[];const result=[];for(const [key,setting] of Object.entries(settings)){if(!setting||typeof setting!=='object')continue;const type=String(setting.type??'text').toLowerCase(),title=__zicTranslateSetting(source,setting.title??key),summaryValue=setting.summary??setting.description??null,summary=summaryValue==null?null:__zicTranslateSetting(source,summaryValue);let kind,value,choices=[];
 if(type==='switch'||type==='bool'||type==='boolean'){kind='toggle';value=Boolean(source.loadSetting(key))}
 else if(type==='select'||type==='dropdown'){kind='select';choices=__zicSettingChoices(source,setting);const loaded=source.loadSetting(key);value=String(loaded??choices[0]?.value??'')}
 else if(type==='multiselect'||type==='multi-select'||type==='multiple'){kind='multiSelect';choices=__zicSettingChoices(source,setting);const loaded=source.loadSetting(key);value=Array.isArray(loaded)?loaded.map(String):(loaded==null?[]:[String(loaded)])}
 else if(type==='callback'||type==='action'||type==='button'){kind='action';value=__zicTranslateSetting(source,setting.buttonText??setting.text??'执行')}
 else if(type==='input'||type==='text'||type==='string'){kind='text';value=String(source.loadSetting(key)??'')}
 else continue;
 result.push({key:String(key),title,summary,kind,value,sensitive:__zicSettingSensitive(key,setting),choices})}return result}
async function __zicUpdateSourceSetting(source,key,value){const setting=source?.settings?.[key];if(!setting||typeof setting!=='object')throw new Error('Venera source setting is unavailable: '+String(key));const type=String(setting.type??'text').toLowerCase();
 if(type==='callback'||type==='action'||type==='button'){if(typeof setting.callback!=='function')throw new Error('Venera source setting action has no callback: '+String(key));const taskStart=__zicSettingActionTasks.length;__zicSettingActionDepth++;try{const result=await Promise.resolve(setting.callback.call(source));await Promise.all(__zicSettingActionTasks.slice(taskStart));return result}finally{__zicSettingActionDepth--;if(__zicSettingActionDepth===0)__zicSettingActionTasks=[]}}
 let normalized=value;
 if(type==='switch'||type==='bool'||type==='boolean'){if(typeof value!=='boolean')throw new Error('Venera switch setting requires a boolean');normalized=value}
 else if(type==='select'||type==='dropdown'){normalized=String(value??'');const choices=__zicSettingChoices(source,setting);if(choices.length&&!choices.some(choice=>choice.value===normalized))throw new Error('Venera select setting value is unavailable: '+normalized)}
 else if(type==='multiselect'||type==='multi-select'||type==='multiple'){if(!Array.isArray(value))throw new Error('Venera multi-select setting requires a list');normalized=value.map(String);const allowed=new Set(__zicSettingChoices(source,setting).map(choice=>choice.value));if(allowed.size&&normalized.some(item=>!allowed.has(item)))throw new Error('Venera multi-select setting contains an unavailable value')}
 else if(type==='input'||type==='text'||type==='string'){normalized=String(value??'')}
 else throw new Error('Unsupported Venera source setting type: '+type);
 source.saveSetting(key,normalized);if(typeof setting.onChanged==='function')await Promise.resolve(setting.onChanged.call(source,normalized));return null}
let __zicSettingActionDepth=0,__zicSettingActionTasks=[];
const UI={
 showMessage(){},
 showDialog:(title,message,buttons=[])=>{if(__zicSettingActionDepth<=0)return Promise.resolve(null);const candidates=Array.isArray(buttons)?buttons:[],action=[...candidates].reverse().find(item=>typeof item?.callback==='function'&&!/cancel|close|no|取消|关闭|否/i.test(String(item?.text??'')))??candidates.find(item=>typeof item?.callback==='function'),task=Promise.resolve().then(()=>action?typeof action.callback==='function'?action.callback():null:null);__zicSettingActionTasks.push(task);return task},
 launchUrl(){},showLoading:()=>0,cancelLoading(){},showInputDialog:async()=>null,showSelectDialog:async()=>null
};
async function compute(func,...args){return (0,eval)('('+func+')')(args)}
function __zicB64(value){return btoa(unescape(encodeURIComponent(JSON.stringify(value)))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','')}
function __zicUnb64(value){let raw=value.replaceAll('-','+').replaceAll('_','/');while(raw.length%4)raw+='=';return JSON.parse(decodeURIComponent(escape(atob(raw))))}
function __zicOptionDefaults(config,encodeDefault=false){return (config?.optionList||[]).map(group=>group.default!=null?(encodeDefault?JSON.stringify(group.default):group.default):String(group.options?.[0]?.value??group.options?.[0]?.key??group.options?.[0]??'').split('-')[0])}
function __zicDefaultOptions(source){return __zicOptionDefaults(source.search,true)}
function __zicHasLoader(value){return typeof value?.load==='function'||typeof value?.loadNext==='function'}
function __zicLoaders(value){if(Array.isArray(value))return value;if(value instanceof Map)return Array.from(value.values());if(value&&typeof value==='object'){if(__zicHasLoader(value))return[value];return Object.values(value)}return[]}
function __zicExploreLoader(source){return __zicLoaders(source.explore).find(__zicHasLoader)||null}
function __zicSearchLoader(source){return __zicHasLoader(source.search)?source.search:null}
function __zicHasSearchCapability(source){return __zicSearchLoader(source)!==null}
function __zicCategoryTarget(source){
 const category=source.category||{};for(const part of category.parts||[]){const items=Array.isArray(part?.categories)?part.categories:__zicLoaders(part?.categories),params=Array.isArray(part?.categoryParams)?part.categoryParams:[];
  for(let index=0;index<items.length;index++){const item=items[index],target=item?.target;if(target?.page==='category'&&target.attributes?.category!==undefined)return target.attributes;
   const itemType=item?.itemType??part?.itemType??category.itemType;if(itemType==='category'){const value=typeof item==='string'?item:(item?.category??item?.value??item?.title??item?.name);if(value!==undefined)return{category:value,param:params[index]??item?.param??item?.categoryParam??null}}
  }
 }return null
}
async function __zicCategoryOptions(source,target){const config=source.categoryComics||{};if(typeof config.optionLoader==='function'){const loaded=await config.optionLoader(target.category,target.param??null),optionList=Array.isArray(loaded)?loaded:(loaded?.optionList||__zicLoaders(loaded));return __zicOptionDefaults({optionList})}return __zicOptionDefaults(config)}
function __zicBrowseSections(source){
 const result=[],explore=__zicLoaders(source.explore).filter(__zicHasLoader);
 for(let index=0;index<explore.length;index++){const loader=explore[index],label=String(loader?.title??loader?.name??('浏览 '+(index+1)));result.push({sectionId:'venera:'+__zicB64({kind:'explore',index}),label})}
 const category=source.category||{};for(const part of category.parts||[]){const items=Array.isArray(part?.categories)?part.categories:__zicLoaders(part?.categories),params=Array.isArray(part?.categoryParams)?part.categoryParams:[];
  for(let index=0;index<items.length;index++){const item=items[index],target=item?.target?.page==='category'?item.target.attributes:null,itemType=item?.itemType??part?.itemType??category.itemType;
   let categoryValue,param,label;if(target?.category!==undefined){categoryValue=target.category;param=target.param??null;label=item?.title??item?.name??item?.label??categoryValue}
   else if(itemType==='category'){categoryValue=typeof item==='string'?item:(item?.category??item?.value??item?.title??item?.name);param=params[index]??item?.param??item?.categoryParam??null;label=item?.title??item?.name??item?.label??categoryValue}
   if(categoryValue!==undefined)result.push({sectionId:'venera:'+__zicB64({kind:'category',category:categoryValue,param}),label:String(label??categoryValue)})}}
 if(!result.length&&__zicSearchLoader(source))result.push({sectionId:'venera:'+__zicB64({kind:'search'}),label:'浏览'});
 const seen=new Set();return result.filter(item=>{if(seen.has(item.sectionId))return false;seen.add(item.sectionId);return true})
}
function __zicBrowseSectionValue(sectionId){const raw=String(sectionId??'');if(!raw.startsWith('venera:'))return null;try{return __zicUnb64(raw.slice(7))}catch(_){return null}}
function __zicHasBrowseCapability(source){return !!(__zicExploreLoader(source)||__zicSearchLoader(source)||(__zicCategoryTarget(source)&&__zicHasLoader(source.categoryComics)))}
function __zicNextToken(result){return result?.next??result?.nextPage??result?.nextToken??result?.cursor??null}
function __zicHasNextToken(value){return value!==null&&value!==undefined&&value!==false&&String(value)!==''}
async function __zicLoadPage(loader,prefixArgs,page,stateKey,requiredCount){
 if(typeof loader?.load==='function')return await loader.load(...prefixArgs,page);
 if(typeof loader?.loadNext!=='function')throw new Error('Venera loader exposes neither load nor loadNext');
 if(page===1)__zicPaging.delete(stateKey);
 let state=__zicPaging.get(stateKey);if(!state){state={pages:[],next:null,exhausted:false,seen:new Set()};__zicPaging.set(stateKey,state)}
 while(__zicFlatten(state.pages).length<requiredCount&&!state.exhausted){if(state.pages.length>=32)throw new Error('Venera cursor pagination exceeded 32 source pages');const next=state.pages.length===0?null:state.next;if(state.pages.length>0&&!__zicHasNextToken(next)){state.exhausted=true;break}const token=JSON.stringify(next);if(state.seen.has(token))throw new Error('Venera cursor pagination repeated a next token');state.seen.add(token);const loaded=await loader.loadNext(...prefixArgs,next);state.pages.push(loaded);state.next=__zicNextToken(loaded);state.exhausted=!__zicHasNextToken(state.next)}
 return {comics:__zicFlatten(state.pages),next:state.next,__zicCursor:true,exhausted:state.exhausted};
}
function __zicAbsoluteUrl(value,base){const text=String(value??'').trim();if(!text)return undefined;try{return new URL(text,base||globalThis.__zicSource?.url||'https://zic.runtime.invalid/').toString()}catch(_){return undefined}}
const __zicChapterMeta=new Map();
function __zicStableComicId(rawId){return 'venera:comic:'+__zicB64({v:2,id:String(rawId??'')})}
function __zicComicOpaque(comicId){return __zicUnb64(String(comicId).slice('venera:comic:'.length))}
function __zicPreviewAsset(value,base){const raw=String(value?.uri??value?.url??value??'').trim();const uri=__zicAbsoluteUrl(raw,base);if(!uri)return null;return {uri,label:value&&typeof value==='object'&&value.label!=null?String(value.label):undefined,width:value&&typeof value==='object'&&Number.isFinite(Number(value.width))?Number(value.width):undefined,height:value&&typeof value==='object'&&Number.isFinite(Number(value.height))?Number(value.height):undefined}}
function __zicPreviewToken(value){if(value==null||value===false||String(value)==='')return null;return typeof value==='string'?value:'__zic-token:'+__zicB64(value)}
function __zicPreviewTokenValue(value){const token=String(value??'');if(token.startsWith('__zic-token:'))return __zicUnb64(token.slice('__zic-token:'.length));return value}
function __zicPreviewPage(value,base){if(value==null)return null;const raw=Array.isArray(value)?value:Array.isArray(value.items)?value.items:Array.isArray(value.thumbnails)?value.thumbnails:Array.isArray(value.data)?value.data:[];const items=raw.map(item=>__zicPreviewAsset(item,base)).filter(Boolean);const next=value&&typeof value==='object'?value.next??value.nextToken??value.cursor??null:null;return {items,nextToken:__zicPreviewToken(next)}}
function __zicComment(value,base){if(!value||typeof value!=='object')return null;return {id:value.id==null?undefined:String(value.id),userName:String(value.userName??value.username??'匿名用户'),avatar:__zicAbsoluteUrl(value.avatar,base),content:String(value.content??''),time:value.time==null?undefined:String(value.time),replyCount:value.replyCount==null?undefined:Number(value.replyCount),score:value.score==null?undefined:Number(value.score),isLiked:value.isLiked==null?undefined:Boolean(value.isLiked),voteStatus:value.voteStatus==null?undefined:Number(value.voteStatus)}}
function __zicCommentPage(value,base,page=1,maxPage=null){if(value==null)return null;const raw=Array.isArray(value)?value:Array.isArray(value.comments)?value.comments:[];const comments=raw.map(item=>__zicComment(item,base)).filter(Boolean);const reported=value&&typeof value==='object'?value.maxPage??maxPage:null;return {page,comments,maxPage:reported==null?null:Number(reported)}}
function __zicComic(item){const rawId=String(item.id??item.comicId??'');const base=/^https?:\/\//i.test(rawId)?rawId:globalThis.__zicSource?.url;const cover=__zicAbsoluteUrl(item.cover,base);return {comicId:__zicStableComicId(rawId),title:String(item.title||'未命名漫画'),authors:[String(item.subtitle??item.subTitle??'')].filter(Boolean),coverUri:cover,description:item.description||undefined,contentRating:'suggestive'}}
function __zicFlatten(result){
 const isComic=value=>value&&typeof value==='object'&&!Array.isArray(value)&&!(value instanceof Map)&&(value.id!==undefined||value.comicId!==undefined)&&value.title!==undefined;
 const unpack=value=>{if(!value)return[];if(isComic(value))return[value];if(Array.isArray(value))return value.flatMap(unpack);if(value instanceof Map)return Array.from(value.values()).flatMap(unpack);if(typeof value==='object')return Object.values(value).flatMap(unpack);return[]};
 return unpack(result)
}
function __zicChapterEntries(raw){const out=[];const visit=(value,fallback)=>{if(value instanceof Map){for(const [k,v] of value.entries())visit(v,k);return}if(Array.isArray(value)){value.forEach((v,i)=>visit(v,String(i)));return}if(value&&typeof value==='object'){if(value.id!==undefined||value.epId!==undefined||value.title!==undefined||value.name!==undefined){out.push([String(value.id??value.epId??fallback),String(value.title??value.name??fallback)]);return}for(const [k,v] of Object.entries(value))visit(v,k);return}out.push([String(fallback),String(value??fallback)])};visit(raw,'0');return out}
function __zicChapterMessage(comicId,epId,title,index,pageCount=0){const opaque=__zicComicOpaque(comicId),comicRawId=String(opaque.id??''),normalizedEpId=epId==null?null:String(epId),revision=normalizedEpId==null?'single':normalizedEpId,chapterId='venera:chapter:'+__zicB64({v:2,comicId,comicRawId,epId:normalizedEpId}),message={comicId,chapterId,title:String(title||('第 '+(index+1)+' 话')),sequence:index,pageCount,sourceRevision:revision};__zicChapterMeta.set(chapterId,{comicId,comicRawId,epId:normalizedEpId,title:message.title,sequence:index});return message}
function __zicImageKindHint(value){const path=String(value??'').split(/[?#]/,1)[0].toLowerCase();if(path.endsWith('.webp'))return 'webp';if(path.endsWith('.gif'))return 'gif';if(path.endsWith('.png'))return 'png';if(path.endsWith('.jpg')||path.endsWith('.jpeg')||path.endsWith('.jpe'))return 'jpeg';if(path.endsWith('.avif'))return 'avif';return null}
async function __zicOperation(request){
 const source=globalThis.__zicSource,args=request.arguments||{};
 if(request.operation==='loadBrowseSections')return __zicBrowseSections(source);
 if(request.operation==='browse'){
  const page=Math.floor(args.offset/args.limit)+1;let loaded;
  const query=String(args.query||''),search=__zicSearchLoader(source),selected=__zicBrowseSectionValue(args.sectionId);
  if(query){if(!search)throw new Error('Venera source does not support search');const options=__zicDefaultOptions(source);loaded=await __zicLoadPage(search,[query,options],page,'search:'+query+':'+JSON.stringify(options),args.offset+args.limit)}
  else if(selected?.kind==='explore'){const loaders=__zicLoaders(source.explore).filter(__zicHasLoader),explore=loaders[Number(selected.index)];if(!explore)throw new Error('Venera browse section is unavailable');loaded=await __zicLoadPage(explore,[],page,'explore:'+String(selected.index)+':'+String(explore.title||'default'),args.offset+args.limit)}
  else if(selected?.kind==='category'&&__zicHasLoader(source.categoryComics)){const target={category:selected.category,param:selected.param??null},options=await __zicCategoryOptions(source,target);loaded=await __zicLoadPage(source.categoryComics,[target.category,target.param,options],page,'category:'+String(target.category)+':'+String(target.param??'')+':'+JSON.stringify(options),args.offset+args.limit)}
  else if(selected?.kind==='search'&&search){const options=__zicDefaultOptions(source);loaded=await __zicLoadPage(search,['',options],page,'search::'+JSON.stringify(options),args.offset+args.limit)}
  else {const sections=__zicBrowseSections(source),fallback=sections[0],value=__zicBrowseSectionValue(fallback?.sectionId);
   if(value?.kind==='explore'){const explore=__zicLoaders(source.explore).filter(__zicHasLoader)[Number(value.index)];loaded=await __zicLoadPage(explore,[],page,'explore:'+String(value.index)+':'+String(explore?.title||'default'),args.offset+args.limit)}
   else if(value?.kind==='category'&&__zicHasLoader(source.categoryComics)){const target={category:value.category,param:value.param??null},options=await __zicCategoryOptions(source,target);loaded=await __zicLoadPage(source.categoryComics,[target.category,target.param,options],page,'category:'+String(target.category)+':'+String(target.param??'')+':'+JSON.stringify(options),args.offset+args.limit)}
   else if(search){const options=__zicDefaultOptions(source);loaded=await __zicLoadPage(search,['',options],page,'search::'+JSON.stringify(options),args.offset+args.limit)}
   else throw new Error('Venera source exposes no browse capability (keys: '+Object.keys(source).join(', ')+')')}
  const all=__zicFlatten(loaded),cursor=loaded?.__zicCursor===true,start=cursor?args.offset:args.offset%args.limit,items=all.slice(start,start+args.limit).map(__zicComic);
  const maxPage=Number(loaded?.maxPage),hasMore=cursor?all.length>start+items.length||!loaded.exhausted:(Number.isFinite(maxPage)&&maxPage>page)||__zicHasNextToken(__zicNextToken(loaded))||all.length>start+items.length;return {items,offset:args.offset,hasMore};
 }
 if(request.operation==='loadComic'){
  const opaque=__zicComicOpaque(args.comicId);const info=await source.comic.loadInfo(opaque.id);
  const chapters=[];let index=0;for(const [epId,title] of __zicChapterEntries(info.chapters||{}))chapters.push(__zicChapterMessage(args.comicId,epId,title,index++));
  if(chapters.length===0&&typeof source.comic.loadEp==='function'){const maxPage=Number(info.maxPage),pageCount=Number.isFinite(maxPage)&&maxPage>0?Math.floor(maxPage):0;chapters.push(__zicChapterMessage(args.comicId,null,info.chapterTitle||'正文',0,pageCount))}
  const base=/^https?:\/\//i.test(String(opaque.id))?String(opaque.id):source.url,cover=__zicAbsoluteUrl(info.cover||opaque.cover,base),preview=typeof source.comic?.loadThumbnails==='function'?null:__zicPreviewPage(info.thumbnails,base),comments=__zicCommentPage(info.comments,base,1,info.commentsMaxPage??info.commentMaxPage);return {comic:{comicId:args.comicId,title:String(info.title||opaque.title||'未命名漫画'),authors:[String(info.subtitle??info.subTitle??opaque.subtitle??'')].filter(Boolean),readingDirection:'vertical',coverUri:cover,description:info.description||opaque.description||undefined,subId:info.subId==null?undefined:String(info.subId)},chapters,preview,comments};
 }
 if(request.operation==='loadComicPreview'){
  const opaque=__zicComicOpaque(args.comicId);if(typeof source.comic?.loadThumbnails!=='function')return {items:[],nextToken:null};const loaded=await source.comic.loadThumbnails(opaque.id,__zicPreviewTokenValue(args.nextToken));const base=/^https?:\/\//i.test(String(opaque.id))?String(opaque.id):source.url;const page=__zicPreviewPage(loaded,base)||{items:[],nextToken:null};return page;
 }
 if(request.operation==='loadComicComments'){
  const opaque=__zicComicOpaque(args.comicId);if(typeof source.comic?.loadComments!=='function')return {page:Number(args.page),comments:[],maxPage:Number(args.page)};const loaded=await source.comic.loadComments(opaque.id,args.subId??null,Number(args.page),args.replyTo??null);const base=/^https?:\/\//i.test(String(opaque.id))?String(opaque.id):source.url;return __zicCommentPage(loaded,base,Number(args.page),null)||{page:Number(args.page),comments:[],maxPage:Number(args.page)};
 }
 if(request.operation==='loadChapter'){
  const chapter=__zicUnb64(args.chapterId.slice('venera:chapter:'.length)),comicRawId=String(chapter.comicRawId??''),epId=chapter.epId==null?null:String(chapter.epId);let meta=__zicChapterMeta.get(args.chapterId);
  if(!meta){let title=chapter.title==null?null:String(chapter.title),sequence=Number.isFinite(Number(chapter.sequence))?Number(chapter.sequence):null,comicId=String(chapter.comicId||__zicStableComicId(comicRawId));if(title==null||sequence==null){const info=await source.comic.loadInfo(comicRawId),entries=__zicChapterEntries(info.chapters||{});for(let i=0;i<entries.length;i++){if(String(entries[i][0])===String(epId)){title=entries[i][1];sequence=i;break}}if(entries.length===0&&epId==null){title=String(info.chapterTitle||'正文');sequence=0}}meta={comicId,comicRawId,epId,title:String(title||'正文'),sequence:Number(sequence??0)};__zicChapterMeta.set(args.chapterId,meta)}
  const loaded=await source.comic.loadEp(meta.comicRawId,meta.epId);const images=Array.isArray(loaded)?loaded:(loaded?.images||[]);
  const pages=[];for(let i=0;i<images.length;i++){const image=String(images[i]),config={image,comicId:meta.comicRawId,epId:meta.epId,deferredImageConfig:true},kind=__zicImageKindHint(image),page={chapterId:args.chapterId,pageId:String(args.chapterId)+':'+i,index:i,uri:__zicResourceUri(config)};if(kind){page.contentKindHint=kind;page.animatedHint=kind==='webp'||kind==='gif'}pages.push(page)}
  return {comicId:meta.comicId,chapter:{comicId:meta.comicId,chapterId:args.chapterId,title:meta.title,sequence:meta.sequence,pageCount:pages.length,sourceRevision:meta.epId==null?'single':String(meta.epId)},pages,readingDirection:'vertical'};
 }
 if(request.operation==='loadSourceAccount')return __zicAccountDescriptor(source);
 if(request.operation==='loginSourceAccount')return await __zicLoginSource(source,String(args.mode||''),args.values||{});
 if(request.operation==='logoutSourceAccount')return await __zicLogoutSource(source);
 if(request.operation==='loadSourceSettings')return __zicSourceSettings(source);
 if(request.operation==='updateSourceSetting')return await __zicUpdateSourceSetting(source,String(args.key||''),args.value);
 if(request.operation==='resolveResource'){
  const uri=String(args.uri||'');const isResource=uri.startsWith('venera-resource:');let config;
  const fresh=args.fresh===true;
  if(fresh){__zicResourceConfigs.delete(uri);__zicResourceResolutions.delete(uri)}
  const planStarted=__zicNowMicros(),bridgeBefore=__zicBridgeNetworkSnapshot(request.requestId);
  if(fresh)__zicFreshResolverDepth++;
  try{
   if(isResource){config=await __zicResolveResourceConfig(uri,source)}
   else if(/^https?:\/\//i.test(uri)){config=await __zicResolveHttpArtworkConfig(uri,source)}
   else throw new Error('Venera resource URI must be a source locator or HTTP(S) URL');
  }finally{if(fresh)__zicFreshResolverDepth=Math.max(0,__zicFreshResolverDepth-1)}
  const bridgeAfter=__zicBridgeNetworkSnapshot(request.requestId),described=__zicDescribeResourceRequest(config);
  described.__zicDiagnostics={sourcePlanHookMicros:Math.max(0,__zicNowMicros()-planStarted),sourcePlanBridgeNetworkMicros:Math.max(0,bridgeAfter.networkMicros-bridgeBefore.networkMicros),sourcePlanBridgeNetworkCalls:Math.max(0,bridgeAfter.networkCalls-bridgeBefore.networkCalls),sourcePlanBridgeNetworkCacheHits:Math.max(0,bridgeAfter.networkCacheHits-bridgeBefore.networkCacheHits),sourcePlanBridgeNetworkOriginCalls:Math.max(0,bridgeAfter.networkOriginCalls-bridgeBefore.networkOriginCalls)};
  return described;
 }
 if(request.operation==='retryResource')return await __zicRetryResourceConfig(String(args.uri||''),source);
 if(request.operation==='loadResource'){
  const uri=String(args.uri||'');const isResource=uri.startsWith('venera-resource:');let config;
  if(isResource){config=await __zicResolveResourceConfig(uri,source)}
  else if(/^https?:\/\//i.test(uri)){config=await __zicResolveHttpArtworkConfig(uri,source)}
  else throw new Error('Venera resource URI must be a source locator or HTTP(S) URL');
  let active=config;while(true){try{const needsJsBytes=typeof active.onResponse==='function'||(typeof active.modifyImage==='string'&&active.modifyImage.trim());if(!needsJsBytes){const direct=await __zicFetchImageBinary(active.method||'GET',active.url,active.headers||{},active.data);if(direct.status<200||direct.status>=300)throw new Error('Venera resource HTTP '+direct.status);if(direct.encodedImage===false)throw new Error('Venera resource returned non-image bytes');if(!direct.nativeBytesToken)throw new Error('Venera native resource payload is unavailable');return {__zicNativeBytesToken:direct.nativeBytesToken}}const response=await Network.fetchBytes(active.method||'GET',active.url,active.headers||{},active.data);if(response.status<200||response.status>=300)throw new Error('Venera resource HTTP '+response.status);let bytes=response.body;if(typeof active.onResponse==='function')bytes=await active.onResponse(bytes);if(typeof active.modifyImage==='string'&&active.modifyImage.trim()){const key=sendMessage({method:'image',function:'decode',data:bytes});try{const modifier=(0,eval)(String(active.modifyImage)+'\n;(typeof modifyImage==="function"?modifyImage:null)');if(typeof modifier!=='function')throw new Error('Venera modifyImage script defines no modifyImage function');const transformed=await Promise.resolve(modifier(new Image(key)));if(!transformed||typeof transformed.key!=='number')throw new Error('Venera modifyImage returned no Image');bytes=sendMessage({method:'image',function:'encode',key:transformed.key})}finally{sendMessage({method:'image',function:'disposeAll'})}}if(!__zicHasEncodedImageSignature(bytes))throw new Error('Venera resource returned non-image bytes');return bytes}catch(error){const retryCount=Math.max(0,Number(active?.__zicSemanticRetryCount||0));if(retryCount>=__zicSemanticRetryLimit||typeof active.onLoadFailed!=='function')throw error;const retry=await Promise.resolve(active.onLoadFailed());if(!retry)throw error;active=__zicRememberResourceConfig(uri,{url:retry.url||active.url,method:retry.method||'GET',headers:retry.headers||{},data:retry.data,onResponse:retry.onResponse,onLoadFailed:retry.onLoadFailed,modifyImage:retry.modifyImage,__zicSemanticRetryCount:retryCount+1})}}
 }
 throw new Error('Unsupported Venera operation');
}
async function __zicInvoke(raw){const request=typeof raw==='string'?JSON.parse(raw):raw,previousRequestId=__zicActiveRequestId;try{await __zicWaitForActivationWork();if(__zicCancelled.has(request.requestId))throw new Error('Venera request was cancelled');__zicActiveRequestId=request.requestId;const value=await __zicOperation(request);if(!__zicCancelled.has(request.requestId))ZicNative.complete(request.requestId,JSON.stringify({ok:true,value:__zicEncode(value)}))}catch(error){const message=__zicErrorMessage(error,request.operation),retryable=/timeout|timed out|connect|network|dns|temporar|HTTP 5\d\d/i.test(message);if(!__zicCancelled.has(request.requestId))ZicNative.complete(request.requestId,JSON.stringify({ok:false,code:'venera-operation-failed',message,retryable}))}finally{__zicBridgeMetrics.delete(request.requestId);__zicCancelled.delete(request.requestId);__zicActiveRequestId=previousRequestId;ZicNative.finished(request.requestId)}}
function __zicCancel(requestId){__zicCancelled.add(requestId);__zicCancelDelays(requestId)}
"""
