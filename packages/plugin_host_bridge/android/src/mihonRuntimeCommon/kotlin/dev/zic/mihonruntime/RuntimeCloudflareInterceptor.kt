package dev.zic.mihonruntime

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.IOException
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response

/**
 * Minimal host implementation of Mihon's Cloudflare WebView bridge.
 *
 * Extensions expect NetworkHelper.client to solve an ordinary Cloudflare
 * browser challenge and persist cf_clearance in Android's CookieManager. The
 * extension itself must remain unaware of the host WebView lifecycle.
 */
class RuntimeCloudflareInterceptor(
    context: Context,
    private val defaultUserAgentProvider: () -> String,
) : Interceptor {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cookieManager = CookieManager.getInstance()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        if (!response.isCloudflareChallenge()) return response

        response.close()
        val previousClearance = clearanceCookie(request.url.toString())
        resolveWithWebView(request, previousClearance)
        return chain.proceed(request)
    }

    private fun resolveWithWebView(request: Request, previousClearance: String?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw IOException("Cloudflare challenge cannot block the Android main thread")
        }
        val latch = CountDownLatch(1)
        var webView: WebView? = null
        var solved = false
        mainHandler.post {
            try {
                val created = WebView(appContext).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.databaseEnabled = true
                    settings.userAgentString = request.header("User-Agent")
                        ?.takeIf(String::isNotBlank)
                        ?: defaultUserAgentProvider()
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String) {
                            val current = clearanceCookie(request.url.toString())
                            if (!current.isNullOrBlank() && current != previousClearance) {
                                solved = true
                                latch.countDown()
                            }
                        }

                        override fun onReceivedHttpError(
                            view: WebView,
                            resourceRequest: WebResourceRequest,
                            errorResponse: WebResourceResponse,
                        ) {
                            if (resourceRequest.isForMainFrame &&
                                errorResponse.statusCode !in CLOUDFLARE_STATUS_CODES
                            ) {
                                latch.countDown()
                            }
                        }
                    }
                }
                webView = created
                cookieManager.setAcceptCookie(true)
                cookieManager.setAcceptThirdPartyCookies(created, true)
                created.loadUrl(request.url.toString(), request.safeWebViewHeaders())
            } catch (_: Throwable) {
                latch.countDown()
            }
        }

        latch.await(CLOUDFLARE_WAIT_SECONDS, TimeUnit.SECONDS)
        mainHandler.post {
            webView?.run {
                stopLoading()
                destroy()
            }
        }
        cookieManager.flush()
        if (!solved) {
            throw IOException(
                "Cloudflare verification failed; open the source login page and retry",
            )
        }
    }

    private fun clearanceCookie(url: String): String? = cookieManager.getCookie(url)
        .orEmpty()
        .split(';')
        .map(String::trim)
        .firstOrNull { it.startsWith("cf_clearance=") }

    private fun Response.isCloudflareChallenge(): Boolean {
        if (code !in CLOUDFLARE_STATUS_CODES ||
            header("Server")?.lowercase(Locale.US) != "cloudflare"
        ) {
            return false
        }
        if (header("cf-mitigated")?.equals("challenge", ignoreCase = true) == true) {
            return true
        }
        val body = runCatching { peekBody(CLOUDFLARE_BODY_LIMIT).string() }
            .getOrDefault("")
            .lowercase(Locale.US)
        return body.contains("cf-mitigated") ||
            body.contains("challenge-platform") ||
            body.contains("just a moment") ||
            body.contains("cf-chl-")
    }

    private fun Request.safeWebViewHeaders(): Map<String, String> = headers
        .filter { (name, value) -> isSafeWebViewHeader(name, value) }
        .associate { it.first to it.second }
}

private fun isSafeWebViewHeader(rawName: String, rawValue: String): Boolean {
    val name = rawName.lowercase(Locale.US)
    val value = rawValue.lowercase(Locale.US)
    if (name in UNSAFE_WEBVIEW_HEADERS || name.startsWith("proxy-")) return false
    return name != "connection" || value != "upgrade"
}

private const val CLOUDFLARE_WAIT_SECONDS = 8L
private const val CLOUDFLARE_BODY_LIMIT = 128L * 1024L
private val CLOUDFLARE_STATUS_CODES = setOf(403, 503)
private val UNSAFE_WEBVIEW_HEADERS = setOf(
    "content-length",
    "host",
    "trailer",
    "te",
    "upgrade",
    "cookie2",
    "keep-alive",
    "transfer-encoding",
    "set-cookie",
)
