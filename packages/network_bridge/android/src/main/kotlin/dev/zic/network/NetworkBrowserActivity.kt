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
            if (cloudflareVerification) {
                clearCloudflareClearance(url) {
                    if (!isFinishing && !isDestroyed) {
                        createBrowser(url, requestedUserAgent)
                    }
                }
            } else {
                createBrowser(url, requestedUserAgent)
            }
        }.onFailure { error ->
            failAndFinish(error.message ?: error.javaClass.simpleName)
        }
    }

    private fun clearCloudflareClearance(url: String, then: () -> Unit) {
        val manager = CookieManager.getInstance()
        manager.setAcceptCookie(true)
        // Mihon discards the ineffective clearance before opening its WebView.
        // Delete both the host-only and common domain forms before loading so
        // an old domain cookie cannot make the visible browser look verified
        // while the isolated HTTP runtime still receives a rejected session.
        val host = runCatching { java.net.URI(url).host.orEmpty() }.getOrDefault("")
        val domains = linkedSetOf<String>()
        if (host.isNotBlank()) {
            domains += host
            if (host.count { it == '.' } >= 2) domains += host.substringAfter('.')
        }
        val deletions = mutableListOf("cf_clearance=; Max-Age=0; Path=/")
        domains.forEach { domain ->
            deletions += "cf_clearance=; Max-Age=0; Path=/; Domain=$domain"
        }
        var remaining = deletions.size
        deletions.forEach { value ->
            manager.setCookie(url, value) {
                remaining--
                if (remaining == 0) {
                    manager.flush()
                    then()
                }
            }
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
                    val cookieHeader = captureSnapshot(view, currentUrl)
                    if (cloudflareVerification && hasClearance(cookieHeader)) {
                        completeAndFinish()
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

    /** Returns the synchronous cookie header used for verification gating. */
    private fun captureSnapshot(view: WebView, currentUrl: String): String? {
        val cookieHeader = CookieManager.getInstance().getCookie(currentUrl)
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
                cookieHeader = CookieManager.getInstance().getCookie(currentUrl),
                localStorageJson = localStorage,
                userAgent = view.settings.userAgentString,
            )
        }
        return cookieHeader
    }

    private fun hasClearance(cookieHeader: String?): Boolean =
        cookieHeader.orEmpty().split(';').any { part ->
            val value = part.trim()
            value.startsWith("cf_clearance=") &&
                value.substringAfter('=', "").isNotBlank()
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
            val cookieHeader = currentUrl.takeIf(String::isNotBlank)?.let { url ->
                captureSnapshot(webView, url)
            }
            if (cloudflareVerification && !hasClearance(cookieHeader)) {
                failAndFinish("Cloudflare verification did not produce cf_clearance")
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

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_USER_AGENT = "userAgent"
        const val EXTRA_ERROR = "error"
        const val EXTRA_CLOUDFLARE_VERIFICATION = "cloudflareVerification"
    }
}
