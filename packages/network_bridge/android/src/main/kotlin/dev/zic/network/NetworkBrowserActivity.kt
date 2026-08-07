package dev.zic.network

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray

class NetworkBrowserActivity : Activity() {
    private lateinit var webView: WebView
    private var cloudflareVerification = false
    private var completing = false
    private var verificationPageResolved: Boolean? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank() ||
            (!url.startsWith("https://") && !url.startsWith("http://"))
        ) {
            failAndFinish("HTTP(S) browser URL is required")
            return
        }
        cloudflareVerification = intent.getBooleanExtra(
            EXTRA_CLOUDFLARE_VERIFICATION,
            false,
        )
        val requestedUserAgent = intent.getStringExtra(EXTRA_USER_AGENT)
            ?.trim()
            ?.takeIf(String::isNotEmpty)
        setResult(RESULT_CANCELED)
        runCatching {
            NetworkBrowserSnapshotStore.begin(this, url, requestedUserAgent)
            // Do not delete the visible browser session before verification.
            // The isolated runtime may simply be missing a still-valid browser
            // cookie; destroying it here creates a verification loop when the
            // page is already accessible and therefore issues no new token.
            createBrowser(url, requestedUserAgent)
        }.onFailure { error ->
            failAndFinish(error.message ?: error.javaClass.simpleName)
        }
    }

    private fun createBrowser(url: String, requestedUserAgent: String?) {
        webView = WebView(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            settings.javaScriptEnabled = true
            if (requestedUserAgent != null) {
                settings.userAgentString = requestedUserAgent
            }
            settings.domStorageEnabled = true
            settings.databaseEnabled = true
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, currentUrl: String) {
                    captureSnapshot(view, currentUrl)
                    if (!cloudflareVerification) return
                    if (!sameSiteWithRequestedUrl(currentUrl)) {
                        verificationPageResolved = null
                        return
                    }
                    view.evaluateJavascript(CLOUDFLARE_CHALLENGE_PROBE) { raw ->
                        if (isFinishing || isDestroyed || completing) return@evaluateJavascript
                        val challengeVisible = raw.trim().equals("true", ignoreCase = true)
                        verificationPageResolved = !challengeVisible
                        if (!challengeVisible) {
                            captureSnapshot(view, currentUrl)
                            completeAndFinish()
                        }
                    }
                }
            }
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }
        setContentView(webView)
        webView.loadUrl(url)
    }

    private fun failAndFinish(message: String) {
        if (completing) return
        completing = true
        setResult(
            RESULT_FIRST_USER,
            Intent().putExtra(EXTRA_ERROR, message.take(500)),
        )
        finish()
    }

    private fun captureSnapshot(view: WebView, currentUrl: String): String? {
        val manager = CookieManager.getInstance()
        val requestedUrl = intent.getStringExtra(EXTRA_URL).orEmpty()
        val cookieHeader = mergeCookieHeaders(
            manager.getCookie(requestedUrl),
            manager.getCookie(currentUrl),
        )
        NetworkBrowserSnapshotStore.update(
            context = this,
            currentUrl = currentUrl,
            title = view.title,
            cookieHeader = cookieHeader,
            userAgent = view.settings.userAgentString,
        )
        view.evaluateJavascript(
            "JSON.stringify(Object.assign({}, window.localStorage))",
        ) { rawValue ->
            val localStorage = runCatching {
                JSONArray("[$rawValue]").optString(0).takeIf(String::isNotBlank)
            }.getOrNull()
            NetworkBrowserSnapshotStore.update(
                context = this,
                currentUrl = currentUrl,
                title = view.title,
                cookieHeader = mergeCookieHeaders(
                    manager.getCookie(requestedUrl),
                    manager.getCookie(currentUrl),
                ),
                localStorageJson = localStorage,
                userAgent = view.settings.userAgentString,
            )
        }
        return cookieHeader
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            completeAndFinish()
        }
    }

    private fun completeAndFinish() {
        if (completing) return
        if (::webView.isInitialized) {
            val currentUrl = webView.url ?: intent.getStringExtra(EXTRA_URL).orEmpty()
            currentUrl.takeIf(String::isNotBlank)?.let { url ->
                captureSnapshot(webView, url)
            }
            if (cloudflareVerification && verificationPageResolved != true) {
                failAndFinish("Cloudflare verification page is still active")
                return
            }
            CookieManager.getInstance().flush()
        } else if (cloudflareVerification) {
            failAndFinish("Cloudflare verification browser did not initialize")
            return
        }
        completing = true
        setResult(RESULT_OK)
        finish()
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            val currentUrl = webView.url ?: intent.getStringExtra(EXTRA_URL).orEmpty()
            if (currentUrl.isNotBlank()) {
                captureSnapshot(webView, currentUrl)
            }
            CookieManager.getInstance().flush()
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }

    private fun sameSiteWithRequestedUrl(currentUrl: String): Boolean {
        val requested = intent.getStringExtra(EXTRA_URL).orEmpty()
        val requestedHost = runCatching { java.net.URI(requested).host.orEmpty() }
            .getOrDefault("")
        val currentHost = runCatching { java.net.URI(currentUrl).host.orEmpty() }
            .getOrDefault("")
        if (requestedHost.isBlank() || currentHost.isBlank()) return false
        val left = requestedHost.lowercase().trimEnd('.')
        val right = currentHost.lowercase().trimEnd('.')
        return left == right || left.endsWith(".$right") || right.endsWith(".$left")
    }

    private fun mergeCookieHeaders(vararg headers: String?): String? {
        val values = linkedMapOf<String, String>()
        for (header in headers) {
            for (raw in header.orEmpty().split(';')) {
                val separator = raw.indexOf('=')
                if (separator <= 0) continue
                val name = raw.substring(0, separator).trim()
                val value = raw.substring(separator + 1).trim()
                if (name.isNotEmpty()) values[name] = value
            }
        }
        if (values.isEmpty()) return null
        return values.entries.joinToString("; ") { (name, value) -> "$name=$value" }
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_USER_AGENT = "userAgent"
        const val EXTRA_ERROR = "error"
        const val EXTRA_CLOUDFLARE_VERIFICATION = "cloudflareVerification"
        private const val CLOUDFLARE_CHALLENGE_PROBE =
            "(function(){" +
                "return !!document.getElementById('challenge-error-title')||" +
                "!!document.getElementById('challenge-error-text');" +
            "})()"
    }
}
