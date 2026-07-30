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
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import java.security.KeyFactory
import java.security.MessageDigest
import java.util.Locale
import java.nio.charset.Charset
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.util.zip.GZIPInputStream
import java.util.zip.InflaterInputStream

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
                result.success(decodeWireValue(envelope.opt("value")) ?: emptyMap<String, Any?>())
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
        pending.remove(requestId)?.error("runtime-request-cancelled", "Venera request was cancelled")
        mainHandler.post { webView.evaluateJavascript("__zicCancel(${requestId.jsQuoted()});", null) }
        bridge.cancel(requestId)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        pending.values.forEach {
            it.error("runtime-closing", "Venera runtime is closing")
        }
        pending.clear()
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
            callback: (Result<VeneraRuntimeDriver>) -> Unit,
        ) {
            check(Looper.myLooper() == Looper.getMainLooper())
            val prepared = runCatching {
                val payload = File(payloadPath)
                verifyVeneraPayload(payload, payloadLength, payloadSha256)
                val script = payload.readText(Charsets.UTF_8)
                val className = Regex(
                    "class\\s+([A-Za-z_$][A-Za-z0-9_$]*)\\s+extends\\s+ComicSource",
                ).find(script)?.groupValues?.get(1)
                    ?: error("Venera script does not declare a ComicSource subclass")
                val sourceKey = activation.requireString("sourceKey")
                val pluginId = activation.requireString("pluginId")
                val pluginVersion = activation.requireString("pluginVersion")
                val capabilities = activation["capabilities"].asVeneraCapabilities()
                val limits = activation["limits"].stringMap("runtime limits")
                val maxResponseBytes = limits.requireLong("maxResponseBytes")
                    .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val webView = WebView(context)
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
                    sourceKey = sourceKey,
                    capabilities = capabilities,
                    maxResponseBytes = maxResponseBytes,
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
            prepared.onFailure { callback(Result.failure(it)) }
            val state = prepared.getOrNull() ?: return
            val completed = AtomicBoolean(false)
            val activationStarted = AtomicBoolean(false)
            val mainHandler = Handler(Looper.getMainLooper())

            fun finish(result: Result<VeneraRuntimeDriver>) {
                if (!completed.compareAndSet(false, true)) return
                state.bridge.activationSink = null
                if (result.isFailure) {
                    state.bridge.close()
                    state.webView.removeJavascriptInterface(BRIDGE_NAME)
                    state.webView.stopLoading()
                    state.webView.destroy()
                }
                callback(result)
            }

            state.bridge.activationSink = { envelope ->
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
        append("();await Promise.resolve(__zicSource.init?.());")
        append("__zicInstallComicInfoCache(__zicSource);")
        append("if(__zicCompareVersion(String(__zicSource.minAppVersion||'0'),appVersion)>0)")
        append("throw new Error('Venera source requires app '+__zicSource.minAppVersion+' or newer');")
        append("const __browse=__zicHasBrowseCapability(__zicSource);")
        append("if(!__browse)throw new Error('Venera source exposes no compatible browse capability');")
        append("ZicNative.activated(JSON.stringify({ok:true,key:String(__zicSource.key||''),")
        append("name:String(__zicSource.name||''),url:String(__zicSource.url||''),")
        append("supportsBrowse:__browse,supportsSearch:__zicHasSearchCapability(__zicSource)}));")
        append("}catch(e){ZicNative.activated(JSON.stringify({ok:false,")
        append("message:__zicErrorMessage(e,'activation')}));}})();")
    }
}

private class VeneraNativeBridge(
    context: Context,
    private val sourceKey: String,
    private val capabilities: Set<String>,
    private val maxResponseBytes: Int,
) : Closeable {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(
        "zic_venera_${sourceKey.replace(Regex("[^A-Za-z0-9_.-]"), "_")}",
        Context.MODE_PRIVATE,
    )
    private val connections = ConcurrentHashMap.newKeySet<Any>()
    private val images = ConcurrentHashMap<Int, Bitmap>()
    private val nextImageKey = AtomicInteger(1)
    private val cookieManager = CookieManager.getInstance()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var dnsFallbackClient: ReflectiveVeneraHttpClient? = null
    @Volatile var resultSink: ((String, JSONObject) -> Unit)? = null
    @Volatile var activationSink: ((JSONObject) -> Unit)? = null

    @JavascriptInterface
    fun request(raw: String): String {
        return runCatching {
            val message = JSONObject(raw)
            val value = when (message.getString("method")) {
                "http" -> http(message)
                "cookie" -> cookie(message)
                "load_data" -> loadData(message)
                "save_data" -> saveData(message)
                "delete_data" -> deleteData(message)
                "load_setting" -> loadSetting(message)
                "convert" -> convert(message)
                "uuid" -> UUID.randomUUID().toString()
                "random" -> random(message)
                "delay" -> {
                    Thread.sleep(message.optLong("time", 0).coerceIn(0, 30_000))
                    null
                }
                "getLocale" -> Locale.getDefault().toLanguageTag().replace('-', '_')
                "getPlatform" -> "android"
                "isLogged" -> false
                "log" -> null
                "image" -> image(message)
                "UI", "setClipboard", "getClipboard", "compute" ->
                    error("Venera capability is not available in background source runtime")
                else -> error("unsupported Venera bridge method")
            }
            JSONObject().put("ok", true).put("value", encodeWireValue(value)).toString()
        }.getOrElse { error ->
            JSONObject()
                .put("ok", false)
                .put("error", error.sanitizedMessage())
                .toString()
        }
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

    fun cancel(requestId: String) {
        cancelled.add(requestId)
    }

    private fun http(message: JSONObject): Any {
        requireCapability("network")
        val url = message.getString("url")
        require(url.startsWith("https://") || url.startsWith("http://")) {
            "Venera network URL must use HTTP(S)"
        }
        val method = message.optString("http_method", "GET").uppercase(Locale.US)
        val headers = veneraRequestHeaders(message.optJSONObject("headers"))
        if (capabilities.contains("cookies")) {
            cookieManager.getCookie(url)?.takeIf { it.isNotBlank() }?.let { cookie ->
                if (headers.keys.none { it.equals("cookie", ignoreCase = true) }) {
                    headers["Cookie"] = cookie
                }
            }
        }
        val data = decodeWireValue(message.opt("data"))
        val bodyBytes = when (data) {
            null -> ByteArray(0)
            is ByteArray -> data
            is String -> data.toByteArray(Charsets.UTF_8)
            else -> JSONObject.wrap(data).toString().toByteArray(Charsets.UTF_8)
        }
        if (method !in setOf("GET", "HEAD") &&
            headers.keys.none { it.equals("content-type", ignoreCase = true) }
        ) {
            headers["Content-Type"] = "application/octet-stream"
        }
        val target = URL(url)
        val result = if (shouldUseVeneraDnsFallback(target) ||
            prefersVeneraDnsFallback(target.host)
        ) {
            httpWithDnsFallback(
                target,
                method,
                headers,
                bodyBytes,
                message.optBoolean("bytes"),
            ).also { rememberVeneraDnsFallback(target.host) }
        } else {
            runCatching {
                httpWithUrlConnection(
                    target,
                    method,
                    headers,
                    bodyBytes,
                    message.optBoolean("bytes"),
                )
            }.recoverCatching { error ->
                if (!shouldRetryVeneraWithDnsFallback(error, target, method)) throw error
                httpWithDnsFallback(
                    target,
                    method,
                    headers,
                    bodyBytes,
                    message.optBoolean("bytes"),
                ).also { rememberVeneraDnsFallback(target.host) }
            }.getOrThrow()
        }
        persistResponseCookies(url, result.optJSONObject("headers"))
        return result
    }

    private fun httpWithUrlConnection(
        target: URL,
        method: String,
        headers: Map<String, String>,
        bodyBytes: ByteArray,
        bytes: Boolean,
    ): JSONObject {
        val connection = target.openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = VENERA_HTTP_CONNECT_TIMEOUT_MILLIS
        connection.readTimeout = VENERA_HTTP_READ_TIMEOUT_MILLIS
        connection.requestMethod = method
        connection.useCaches = false
        headers.forEach(connection::setRequestProperty)
        if (method !in setOf("GET", "HEAD")) connection.doOutput = true
        connections.add(connection)
        try {
            if (connection.doOutput) connection.outputStream.use { it.write(bodyBytes) }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val responseBytes = stream?.let {
                readDecodedResponseBytes(
                    it,
                    connection.getHeaderField("Content-Encoding"),
                    maxResponseBytes,
                )
            } ?: ByteArray(0)
            return veneraResponse(
                status = status,
                headers = connection.headerFields,
                body = responseBytes,
                bytes = bytes,
            )
        } finally {
            connections.remove(connection)
            connection.disconnect()
        }
    }

    private fun httpWithDnsFallback(
        target: URL,
        method: String,
        headers: Map<String, String>,
        bodyBytes: ByteArray,
        bytes: Boolean,
    ): JSONObject {
        val resolved = resolveVeneraPublicAddresses(target.host)
        require(resolved.isNotEmpty()) {
            "Venera public DNS fallback returned no safe address for ${target.host}"
        }
        val call = getDnsFallbackClient().newCall(target, method, headers, bodyBytes)
        connections.add(call)
        try {
            val response = call.execute()
                ?: error("Venera DNS fallback returned no response")
            try {
                val status = response.javaClass.methods.first {
                    it.name in setOf("code", "getCode") && it.parameterCount == 0
                }.invoke(response) as Number
                val responseHeaders = response.javaClass.methods.first {
                    it.name in setOf("headers", "getHeaders") && it.parameterCount == 0
                }.invoke(response)
                @Suppress("UNCHECKED_CAST")
                val headerMap = responseHeaders.javaClass.methods.first {
                    it.name == "toMultimap" && it.parameterCount == 0
                }.invoke(responseHeaders) as Map<String, List<String>>
                val contentEncoding = headerMap.entries.firstOrNull {
                    it.key.equals("content-encoding", ignoreCase = true)
                }?.value?.joinToString(",")
                val body = response.javaClass.methods.first {
                    it.name in setOf("body", "getBody") && it.parameterCount == 0
                }.invoke(response)
                val stream = body?.javaClass?.methods?.firstOrNull {
                    it.name == "byteStream" && it.parameterCount == 0
                }?.invoke(body) as? InputStream
                val responseBytes = stream?.let {
                    readDecodedResponseBytes(it, contentEncoding, maxResponseBytes)
                } ?: ByteArray(0)
                return veneraResponse(status.toInt(), headerMap, responseBytes, bytes)
            } finally {
                runCatching {
                    response.javaClass.methods.first {
                        it.name == "close" && it.parameterCount == 0
                    }.invoke(response)
                }
            }
        } finally {
            connections.remove(call)
            call.close()
        }
    }

    private fun getDnsFallbackClient(): ReflectiveVeneraHttpClient {
        dnsFallbackClient?.let { return it }
        synchronized(this) {
            dnsFallbackClient?.let { return it }
            return createReflectiveVeneraHttpClient().also { dnsFallbackClient = it }
        }
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
                require(srcX >= 0 && srcY >= 0 && width > 0 && height > 0 &&
                    srcX + width <= source.width && srcY + height <= source.height) {
                    "Venera image source range is out of bounds"
                }
                val x = message.getInt("x")
                val y = message.getInt("y")
                Canvas(target).drawBitmap(
                    source,
                    Rect(srcX, srcY, srcX + width, srcY + height),
                    Rect(x, y, x + width, y + height),
                    null,
                )
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
                val cookies = message.optJSONArray("cookies") ?: JSONArray()
                repeat(cookies.length()) { index ->
                    val cookie = cookies.getJSONObject(index)
                    val value = buildString {
                        append(cookie.getString("name"))
                        append('=')
                        append(cookie.getString("value"))
                        cookie.optString("domain").takeIf { it.isNotBlank() }?.let {
                            append("; Domain=")
                            append(it)
                        }
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
        return preferences.getString("setting:${message.getString("setting_key")}", null)
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
        activationSink = null
        resultSink = null
        cancelled.clear()
        connections.toList().forEach { connection ->
            when (connection) {
                is HttpURLConnection -> connection.disconnect()
                is ReflectiveVeneraCall -> connection.cancel()
                else -> Unit
            }
        }
        connections.clear()
        dnsFallbackClient?.close()
        dnsFallbackClient = null
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

private fun java.io.InputStream.readBytesBounded(maxBytes: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream(minOf(maxBytes, 64 * 1024))
    val buffer = ByteArray(16 * 1024)
    var total = 0
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        total += count
        require(total <= maxBytes) { "Venera response exceeds runtime limit" }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
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

private fun veneraRequestHeaders(raw: JSONObject?): LinkedHashMap<String, String> {
    val headers = LinkedHashMap<String, String>()
    raw?.keys()?.forEach { name ->
        if (!name.equals("accept-encoding", ignoreCase = true)) {
            headers[name] = raw.optString(name)
        }
    }
    val requestedEncoding = raw?.keys()?.asSequence()?.firstOrNull {
        it.equals("accept-encoding", ignoreCase = true)
    }?.let { name -> raw.optString(name) }
    headers["Accept-Encoding"] = normalizeVeneraAcceptEncoding(requestedEncoding)
    return headers
}

private fun veneraResponse(
    status: Int,
    headers: Map<*, *>,
    body: ByteArray,
    bytes: Boolean,
): JSONObject {
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
    return JSONObject()
        .put("status", status)
        .put("headers", responseHeaders)
        .put("body", if (bytes) encodeWireValue(body) else body.toString(Charsets.UTF_8))
}

private fun isPublicVeneraHost(host: String): Boolean {
    if (host.isBlank() || !host.contains('.') || host.equals("localhost", true)) return false
    if (looksLikeNumericAddress(host) &&
        (host.contains(':') || host.count { it == '.' } == 3)
    ) {
        return false
    }
    return !host.endsWith(".local", true) && !host.endsWith(".localhost", true)
}

internal fun isSafeVeneraPublicAddress(address: InetAddress): Boolean =
    !address.isAnyLocalAddress && !address.isLoopbackAddress &&
        !address.isLinkLocalAddress && !address.isSiteLocalAddress &&
        !address.isMulticastAddress

internal fun shouldUseVeneraDnsFallback(target: URL): Boolean {
    if (!isPublicVeneraHost(target.host)) return false
    val addresses = runCatching { InetAddress.getAllByName(target.host).toList() }.getOrElse {
        return it is UnknownHostException
    }
    return addresses.isNotEmpty() && addresses.none(::isSafeVeneraPublicAddress)
}

internal fun shouldRetryVeneraWithDnsFallback(
    error: Throwable,
    target: URL,
    method: String,
): Boolean {
    if (!isPublicVeneraHost(target.host)) return false
    val idempotent = method in setOf("GET", "HEAD", "OPTIONS")
    var current: Throwable? = error
    while (current != null) {
        if (current is UnknownHostException) return true
        if (idempotent && current is ConnectException) return true
        if (idempotent && current is NoRouteToHostException) return true
        if (idempotent && current is SocketTimeoutException) return true
        val message = current.message.orEmpty().lowercase(Locale.US)
        if (message.contains("/127.0.0.1") || message.contains("/0:0:0:0:0:0:0:1")) return true
        if (idempotent && current is SocketException &&
            (message.contains("connection reset") ||
                message.contains("network is unreachable") ||
                message.contains("failed to connect"))
        ) {
            return true
        }
        current = current.cause
    }
    return false
}

internal fun parseVeneraDnsJson(raw: String): List<InetAddress> {
    val answers = runCatching { JSONObject(raw).optJSONArray("Answer") }.getOrNull()
        ?: return emptyList()
    val result = LinkedHashMap<String, InetAddress>()
    repeat(answers.length()) { index ->
        val answer = answers.optJSONObject(index) ?: return@repeat
        if (answer.optInt("type") !in setOf(1, 28)) return@repeat
        val value = answer.optString("data").trim()
        if (!looksLikeNumericAddress(value)) return@repeat
        runCatching { InetAddress.getByName(value) }.getOrNull()
            ?.takeIf(::isSafeVeneraPublicAddress)
            ?.let { result[it.hostAddress] = it }
    }
    return result.values.toList()
}

private fun looksLikeNumericAddress(value: String): Boolean =
    value.isNotBlank() && value.all { character ->
        character.isDigit() || character in setOf('.', ':') ||
            character.lowercaseChar() in 'a'..'f'
    }

private data class VeneraDnsCacheEntry(
    val addresses: List<InetAddress>,
    val expiresAtNanos: Long,
)

private const val VENERA_DNS_CACHE_NANOS = 5L * 60L * 1_000_000_000L
private const val VENERA_HTTP_CONNECT_TIMEOUT_MILLIS = 5_000
private const val VENERA_HTTP_READ_TIMEOUT_MILLIS = 10_000
private const val VENERA_HTTP_CALL_TIMEOUT_MILLIS = 15_000L
private const val VENERA_DOH_TIMEOUT_MILLIS = 1_500
private val veneraDnsCache = ConcurrentHashMap<String, VeneraDnsCacheEntry>()
private val veneraDnsFallbackPreferences = ConcurrentHashMap<String, Long>()

private fun prefersVeneraDnsFallback(host: String): Boolean {
    val cacheKey = host.lowercase(Locale.US)
    val expiry = veneraDnsFallbackPreferences[cacheKey] ?: return false
    if (expiry - System.nanoTime() > 0) return true
    veneraDnsFallbackPreferences.remove(cacheKey, expiry)
    return false
}

private fun rememberVeneraDnsFallback(host: String) {
    veneraDnsFallbackPreferences[host.lowercase(Locale.US)] =
        System.nanoTime() + VENERA_DNS_CACHE_NANOS
}

private fun resolveVeneraPublicAddresses(host: String): List<InetAddress> {
    require(isPublicVeneraHost(host)) { "Venera DNS fallback requires a public hostname" }
    val cacheKey = host.lowercase(Locale.US)
    val now = System.nanoTime()
    veneraDnsCache[cacheKey]?.takeIf { it.expiresAtNanos - now > 0 }?.let {
        return it.addresses
    }
    val encodedHost = java.net.URLEncoder.encode(host, "UTF-8")
    for (recordType in listOf("A", "AAAA")) {
        val endpoints = listOf(
            "https://cloudflare-dns.com/dns-query?name=$encodedHost&type=$recordType",
            "https://dns.google/resolve?name=$encodedHost&type=$recordType",
            "https://dns.alidns.com/resolve?name=$encodedHost&type=$recordType",
            "https://doh.pub/dns-query?name=$encodedHost&type=$recordType",
        )
        for (endpoint in endpoints) {
            val connection = URL(endpoint).openConnection() as HttpURLConnection
            connection.connectTimeout = VENERA_DOH_TIMEOUT_MILLIS
            connection.readTimeout = VENERA_DOH_TIMEOUT_MILLIS
            connection.setRequestProperty("Accept", "application/dns-json")
            val addresses = runCatching {
                if (connection.responseCode !in 200..299) {
                    emptyList()
                } else {
                    parseVeneraDnsJson(
                        connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() },
                    )
                }
            }.getOrDefault(emptyList())
            connection.disconnect()
            if (addresses.isNotEmpty()) {
                veneraDnsCache[cacheKey] = VeneraDnsCacheEntry(
                    addresses = addresses,
                    expiresAtNanos = System.nanoTime() + VENERA_DNS_CACHE_NANOS,
                )
                return addresses
            }
        }
    }
    return emptyList()
}

private class ReflectiveVeneraHttpClient(
    private val client: Any,
) : Closeable {
    fun newCall(
        target: URL,
        method: String,
        headers: Map<String, String>,
        bodyBytes: ByteArray,
    ): ReflectiveVeneraCall =
        createReflectiveOkHttpCall(client, target, method, headers, bodyBytes)

    override fun close() {
        runCatching {
            val pool = client.javaClass.methods.firstOrNull {
                it.name in setOf("connectionPool", "getConnectionPool") && it.parameterCount == 0
            }?.invoke(client)
            pool?.javaClass?.methods?.firstOrNull {
                it.name == "evictAll" && it.parameterCount == 0
            }?.invoke(pool)
        }
        runCatching {
            val dispatcher = client.javaClass.methods.firstOrNull {
                it.name in setOf("dispatcher", "getDispatcher") && it.parameterCount == 0
            }?.invoke(client)
            val executor = dispatcher?.javaClass?.methods?.firstOrNull {
                it.name in setOf("executorService", "getExecutorService") && it.parameterCount == 0
            }?.invoke(dispatcher) as? java.util.concurrent.ExecutorService
            executor?.shutdown()
        }
    }
}

private class ReflectiveVeneraCall(
    private val call: Any,
) : Closeable {
    fun execute(): Any = call.javaClass.methods.first {
        it.name == "execute" && it.parameterCount == 0
    }.invoke(call) ?: error("Venera DNS fallback returned no response")

    fun cancel() {
        runCatching {
            call.javaClass.methods.firstOrNull {
                it.name == "cancel" && it.parameterCount == 0
            }?.invoke(call)
        }
    }

    override fun close() {
        cancel()
    }
}

private fun createReflectiveVeneraHttpClient(): ReflectiveVeneraHttpClient {
    val loader = requireNotNull(VeneraRuntimeDriver::class.java.classLoader) {
        "Venera runtime class loader is unavailable"
    }
    val dnsType = loader.loadClass("okhttp3.Dns")
    val dns = Proxy.newProxyInstance(loader, arrayOf(dnsType), InvocationHandler { proxy, invoked, args ->
        when (invoked.name) {
            "lookup" -> {
                val hostname = args?.firstOrNull()?.toString().orEmpty()
                val addresses = if (isPublicVeneraHost(hostname)) {
                    resolveVeneraPublicAddresses(hostname)
                } else {
                    InetAddress.getAllByName(hostname).toList()
                }
                addresses.ifEmpty {
                    throw UnknownHostException("No safe Venera DNS answer for $hostname")
                }
            }
            "toString" -> "ZicVeneraDns"
            "hashCode" -> System.identityHashCode(proxy)
            "equals" -> args?.firstOrNull() === proxy
            else -> null
        }
    })
    val clientBuilderType = loader.loadClass("okhttp3.OkHttpClient${'$'}Builder")
    val clientBuilder = clientBuilderType.getDeclaredConstructor().newInstance()
    clientBuilderType.methods.first { it.name == "dns" && it.parameterCount == 1 }
        .invoke(clientBuilder, dns)
    clientBuilderType.methods.first {
        it.name == "connectTimeout" && it.parameterCount == 2
    }.invoke(
        clientBuilder,
        VENERA_HTTP_CONNECT_TIMEOUT_MILLIS.toLong(),
        TimeUnit.MILLISECONDS,
    )
    clientBuilderType.methods.first {
        it.name == "readTimeout" && it.parameterCount == 2
    }.invoke(
        clientBuilder,
        VENERA_HTTP_READ_TIMEOUT_MILLIS.toLong(),
        TimeUnit.MILLISECONDS,
    )
    clientBuilderType.methods.first {
        it.name == "callTimeout" && it.parameterCount == 2
    }.invoke(
        clientBuilder,
        VENERA_HTTP_CALL_TIMEOUT_MILLIS,
        TimeUnit.MILLISECONDS,
    )
    val client = requireNotNull(
        clientBuilderType.methods.first { it.name == "build" && it.parameterCount == 0 }
            .invoke(clientBuilder),
    ) { "Venera DNS fallback client build returned null" }
    return ReflectiveVeneraHttpClient(client)
}

private fun createReflectiveOkHttpCall(
    client: Any,
    target: URL,
    method: String,
    headers: Map<String, String>,
    bodyBytes: ByteArray,
): ReflectiveVeneraCall {
    val loader = requireNotNull(VeneraRuntimeDriver::class.java.classLoader) {
        "Venera runtime class loader is unavailable"
    }
    val requestBuilderType = loader.loadClass("okhttp3.Request${'$'}Builder")
    val requestBuilder = requestBuilderType.getDeclaredConstructor().newInstance()
    requestBuilderType.methods.first { it.name == "url" && it.parameterTypes.contentEquals(arrayOf(String::class.java)) }
        .invoke(requestBuilder, target.toString())
    val addHeader = requestBuilderType.methods.first {
        it.name == "addHeader" && it.parameterCount == 2
    }
    headers.forEach { (name, value) -> addHeader.invoke(requestBuilder, name, value) }
    val body = if (method in setOf("GET", "HEAD")) null else reflectiveRequestBody(loader, bodyBytes)
    requestBuilderType.methods.first { it.name == "method" && it.parameterCount == 2 }
        .invoke(requestBuilder, method, body)
    val request = requestBuilderType.methods.first { it.name == "build" && it.parameterCount == 0 }
        .invoke(requestBuilder)
    val call = client.javaClass.methods.first { it.name == "newCall" && it.parameterCount == 1 }
        .invoke(client, request)
    return ReflectiveVeneraCall(call)
}

private fun reflectiveRequestBody(loader: ClassLoader, bytes: ByteArray): Any {
    val type = loader.loadClass("okhttp3.RequestBody")
    val companion = type.getField("Companion").get(null)
    val create = companion.javaClass.methods.firstOrNull { method ->
        method.name == "create" && method.parameterCount == 2 &&
            method.parameterTypes.any { it == ByteArray::class.java }
    } ?: error("OkHttp RequestBody.create(byte[]) is unavailable")
    val arguments = create.parameterTypes.map { parameter ->
        when {
            parameter == ByteArray::class.java -> bytes
            else -> null
        }
    }.toTypedArray()
    return create.invoke(companion, *arguments)
}

internal fun readDecodedResponseBytes(
    input: InputStream,
    contentEncoding: String?,
    maxBytes: Int,
): ByteArray {
    val encodings = contentEncoding.orEmpty()
        .split(',')
        .map { it.trim().lowercase(Locale.US) }
        .filter { it.isNotEmpty() && it != "identity" }
    val decoded = encodings.asReversed().fold(input) { stream, encoding ->
        when (encoding) {
            "gzip", "x-gzip" -> GZIPInputStream(stream)
            "deflate" -> InflaterInputStream(stream)
            else -> throw IllegalArgumentException(
                "Unsupported Venera response content encoding: $encoding",
            )
        }
    }
    return decoded.use { it.readBytesBounded(maxBytes) }
}

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
const __zicPaging = new Map();
let __zicResourceKey = 0;
function __zicRetainResource(config){const token=String(++__zicResourceKey);__zicResources.set(token,config);while(__zicResources.size>__zicResourceLimit)__zicResources.delete(__zicResources.keys().next().value);return token}
function __zicGetResource(token){const config=__zicResources.get(token);if(config){__zicResources.delete(token);__zicResources.set(token,config)}return config}
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
function sendMessage(message) {
  const envelope = JSON.parse(ZicNative.request(JSON.stringify(__zicEncode(message))));
  if (!envelope.ok) throw new Error(envelope.error || 'Venera bridge failed');
  return __zicDecode(envelope.value);
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
const Network = {
  fetchBytes:async(method,url,headers,data,extra)=>sendMessage({method:'http',http_method:method,bytes:true,url,headers:headers||{},data,extra}),
  sendRequest:async(method,url,headers,data,extra)=>sendMessage({method:'http',http_method:method,url,headers:headers||{},data,extra}),
  get(url,headers,extra){return this.sendRequest('GET',url,headers,undefined,extra)}, post(url,headers,data,extra){return this.sendRequest('POST',url,headers,data,extra)},
  put(url,headers,data,extra){return this.sendRequest('PUT',url,headers,data,extra)}, patch(url,headers,data,extra){return this.sendRequest('PATCH',url,headers,data,extra)},
  delete(url,headers,extra){return this.sendRequest('DELETE',url,headers,undefined,extra)},
  setCookies(url,cookies){return sendMessage({method:'cookie',function:'set',url,cookies})},
  getCookies(url){return sendMessage({method:'cookie',function:'get',url})},
  deleteCookies(url){return sendMessage({method:'cookie',function:'delete',url})},
};
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
  get isLogged(){return sendMessage({method:'isLogged',key:this.key})}
  translate(key){return this.translation?.[APP.locale]?.[key]??key}
}
const APP={get version(){return appVersion},get locale(){return sendMessage({method:'getLocale'})},get platform(){return 'android'}};
const UI={showMessage(){},showDialog:async()=>{},launchUrl(){},showLoading:()=>0,cancelLoading(){},showInputDialog:async()=>null,showSelectDialog:async()=>null};
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
function __zicComic(item){const rawId=String(item.id??item.comicId??'');const base=/^https?:\/\//i.test(rawId)?rawId:globalThis.__zicSource?.url;const cover=__zicAbsoluteUrl(item.cover,base);return {comicId:'venera:comic:'+__zicB64({id:rawId,title:String(item.title||''),subtitle:String(item.subtitle??item.subTitle??''),cover:String(cover||''),description:String(item.description||'')}),title:String(item.title||'未命名漫画'),authors:[String(item.subtitle??item.subTitle??'')].filter(Boolean),coverUri:cover,description:item.description||undefined,contentRating:'suggestive'}}
function __zicFlatten(result){
 const isComic=value=>value&&typeof value==='object'&&!Array.isArray(value)&&!(value instanceof Map)&&(value.id!==undefined||value.comicId!==undefined)&&value.title!==undefined;
 const unpack=value=>{if(!value)return[];if(isComic(value))return[value];if(Array.isArray(value))return value.flatMap(unpack);if(value instanceof Map)return Array.from(value.values()).flatMap(unpack);if(typeof value==='object')return Object.values(value).flatMap(unpack);return[]};
 return unpack(result)
}
function __zicChapterEntries(raw){const out=[];const visit=(value,fallback)=>{if(value instanceof Map){for(const [k,v] of value.entries())visit(v,k);return}if(Array.isArray(value)){value.forEach((v,i)=>visit(v,String(i)));return}if(value&&typeof value==='object'){if(value.id!==undefined||value.epId!==undefined||value.title!==undefined||value.name!==undefined){out.push([String(value.id??value.epId??fallback),String(value.title??value.name??fallback)]);return}for(const [k,v] of Object.entries(value))visit(v,k);return}out.push([String(fallback),String(value??fallback)])};visit(raw,'0');return out}
function __zicInstallComicInfoCache(source){
 const comic=source?.comic;if(!comic||typeof comic.loadInfo!=='function'||comic.loadInfo.__zicCached)return;
 const original=comic.loadInfo,cache=new Map(),ttl=60000,maxEntries=32;
 const cached=async function(...args){
  let key;try{key=JSON.stringify(args)}catch(_){return original.apply(this,args)}
  const now=Date.now(),existing=cache.get(key);
  if(existing&&existing.expires>now)return existing.promise;
  const promise=Promise.resolve().then(()=>original.apply(this,args));
  cache.set(key,{expires:now+ttl,promise});
  promise.catch(()=>{if(cache.get(key)?.promise===promise)cache.delete(key)});
  while(cache.size>maxEntries)cache.delete(cache.keys().next().value);
  return promise
 };
 Object.defineProperty(cached,'__zicCached',{value:true});comic.loadInfo=cached
}
function __zicChapterMessage(comicId,epId,title,index,pageCount=0){const revision=epId==null?'single':String(epId);return {comicId,chapterId:'venera:chapter:'+__zicB64({comicId,comicRawId:__zicUnb64(comicId.slice('venera:comic:'.length)).id,epId:epId==null?null:String(epId),title:String(title),sequence:index}),title:String(title||('第 '+(index+1)+' 话')),sequence:index,pageCount,sourceRevision:revision}}
async function __zicOperation(request){
 const source=globalThis.__zicSource,args=request.arguments||{};
 if(request.operation==='browse'){
  const page=Math.floor(args.offset/args.limit)+1;let loaded;
  const query=String(args.query||''),explore=__zicExploreLoader(source),search=__zicSearchLoader(source),category=__zicCategoryTarget(source);
  if(query){if(!search)throw new Error('Venera source does not support search');const options=__zicDefaultOptions(source);loaded=await __zicLoadPage(search,[query,options],page,'search:'+query+':'+JSON.stringify(options),args.offset+args.limit)}
  else if(explore) loaded=await __zicLoadPage(explore,[],page,'explore:'+String(explore.title||'default'),args.offset+args.limit);
  else if(search){const options=__zicDefaultOptions(source);loaded=await __zicLoadPage(search,['',options],page,'search::'+JSON.stringify(options),args.offset+args.limit)}
  else if(category&&__zicHasLoader(source.categoryComics)){const options=await __zicCategoryOptions(source,category);loaded=await __zicLoadPage(source.categoryComics,[category.category,category.param??null,options],page,'category:'+String(category.category)+':'+String(category.param??'')+':'+JSON.stringify(options),args.offset+args.limit)}
  else throw new Error('Venera source exposes no browse capability (keys: '+Object.keys(source).join(', ')+')');
  const all=__zicFlatten(loaded),cursor=loaded?.__zicCursor===true,start=cursor?args.offset:args.offset%args.limit,items=all.slice(start,start+args.limit).map(__zicComic);
  const maxPage=Number(loaded?.maxPage),hasMore=cursor?all.length>start+items.length||!loaded.exhausted:(Number.isFinite(maxPage)&&maxPage>page)||__zicHasNextToken(__zicNextToken(loaded))||all.length>start+items.length;return {items,offset:args.offset,hasMore};
 }
 if(request.operation==='loadComic'){
  const opaque=__zicUnb64(args.comicId.slice('venera:comic:'.length));const info=await source.comic.loadInfo(opaque.id);
  const chapters=[];let index=0;for(const [epId,title] of __zicChapterEntries(info.chapters||{}))chapters.push(__zicChapterMessage(args.comicId,epId,title,index++));
  if(chapters.length===0&&typeof source.comic.loadEp==='function'){const maxPage=Number(info.maxPage),pageCount=Number.isFinite(maxPage)&&maxPage>0?Math.floor(maxPage):0;chapters.push(__zicChapterMessage(args.comicId,null,info.chapterTitle||'正文',0,pageCount))}
  const cover=__zicAbsoluteUrl(info.cover||opaque.cover,/^https?:\/\//i.test(String(opaque.id))?String(opaque.id):source.url);return {comic:{comicId:args.comicId,title:String(info.title||opaque.title||'未命名漫画'),authors:[String(info.subtitle??info.subTitle??opaque.subtitle??'')].filter(Boolean),readingDirection:'vertical',coverUri:cover,description:info.description||opaque.description||undefined},chapters};
 }
 if(request.operation==='loadChapter'){
  const chapter=__zicUnb64(args.chapterId.slice('venera:chapter:'.length));const loaded=await source.comic.loadEp(chapter.comicRawId,chapter.epId);const images=Array.isArray(loaded)?loaded:(loaded?.images||[]);
  const pages=[];for(let i=0;i<images.length;i++){const token=__zicRetainResource({image:String(images[i]),comicId:chapter.comicRawId,epId:chapter.epId,deferredImageConfig:true});pages.push({chapterId:args.chapterId,pageId:String(args.chapterId)+':'+i,index:i,uri:'venera-resource://'+token})}
  return {comicId:chapter.comicId,chapter:__zicChapterMessage(chapter.comicId,chapter.epId,chapter.title,chapter.sequence,pages.length),pages,readingDirection:'vertical'};
 }
 if(request.operation==='loadResource'){
  const uri=String(args.uri||'');const isToken=uri.startsWith('venera-resource://');let token=null,config;
  if(isToken){token=uri.slice('venera-resource://'.length);config=__zicGetResource(token);if(!config)throw new Error('Venera resource token expired')}
  else if(/^https?:\/\//i.test(uri)){let override={};if(typeof source.comic?.onImageLoad==='function'){try{override=await Promise.resolve(source.comic.onImageLoad(uri,null,null))||{}}catch(_){override={}}}config={url:override.url||uri,method:override.method||'GET',headers:override.headers||{},data:override.data,onResponse:override.onResponse,onLoadFailed:override.onLoadFailed,modifyImage:override.modifyImage}}
  else throw new Error('Venera resource URI must be a runtime token or HTTP(S) URL');
  if(config.deferredImageConfig){const original=config.image;const override=await Promise.resolve(source.comic?.onImageLoad?.(original,config.comicId,config.epId)||{});config={url:override.url||original,method:override.method||'GET',headers:override.headers||{},data:override.data,onResponse:override.onResponse,onLoadFailed:override.onLoadFailed,modifyImage:override.modifyImage}}
  let active=config;for(let attempt=0;attempt<2;attempt++){try{const response=await Network.fetchBytes(active.method||'GET',active.url,active.headers||{},active.data);if(response.status<200||response.status>=300)throw new Error('Venera resource HTTP '+response.status);let bytes=response.body;if(typeof active.onResponse==='function')bytes=await active.onResponse(bytes);if(typeof active.modifyImage==='string'&&active.modifyImage.trim()){const key=sendMessage({method:'image',function:'decode',data:bytes});try{const modifier=(0,eval)(String(active.modifyImage)+'\n;(typeof modifyImage==="function"?modifyImage:null)');if(typeof modifier!=='function')throw new Error('Venera modifyImage script defines no modifyImage function');const transformed=await Promise.resolve(modifier(new Image(key)));if(!transformed||typeof transformed.key!=='number')throw new Error('Venera modifyImage returned no Image');bytes=sendMessage({method:'image',function:'encode',key:transformed.key})}finally{sendMessage({method:'image',function:'disposeAll'})}}return bytes}catch(error){if(attempt||typeof active.onLoadFailed!=='function')throw error;const retry=await active.onLoadFailed();if(!retry)throw error;active={url:retry.url||active.url,method:retry.method||'GET',headers:retry.headers||{},data:retry.data,onResponse:retry.onResponse,onLoadFailed:retry.onLoadFailed,modifyImage:retry.modifyImage}}}throw new Error('Venera resource retry exhausted')
 }
 throw new Error('Unsupported Venera operation');
}
async function __zicInvoke(raw){const request=typeof raw==='string'?JSON.parse(raw):raw;try{const value=await __zicOperation(request);if(!__zicCancelled.has(request.requestId))ZicNative.complete(request.requestId,JSON.stringify({ok:true,value:__zicEncode(value)}))}catch(error){const message=__zicErrorMessage(error,request.operation),retryable=/timeout|timed out|connect|network|dns|temporar|HTTP 5\d\d/i.test(message);if(!__zicCancelled.has(request.requestId))ZicNative.complete(request.requestId,JSON.stringify({ok:false,code:'venera-operation-failed',message,retryable}))}finally{__zicCancelled.delete(request.requestId)}}
function __zicCancel(requestId){__zicCancelled.add(requestId)}
"""
