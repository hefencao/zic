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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank() ||
            (!url.startsWith("https://") && !url.startsWith("http://"))
        ) {
            failAndFinish("HTTP(S) browser URL is required")
            return
        }
        val requestedUserAgent = intent.getStringExtra(EXTRA_USER_AGENT)
            ?.trim()
            ?.takeIf(String::isNotEmpty)
        setResult(RESULT_CANCELED)
        runCatching {
            NetworkBrowserSnapshotStore.begin(this, url, requestedUserAgent)
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
                    }
                }
            }
            CookieManager.getInstance().apply {
                setAcceptCookie(true)
                setAcceptThirdPartyCookies(webView, true)
            }
            setContentView(webView)
            webView.loadUrl(url)
        }.onFailure { error ->
            failAndFinish(error.message ?: error.javaClass.simpleName)
        }
    }

    private fun failAndFinish(message: String) {
        setResult(
            RESULT_FIRST_USER,
            Intent().putExtra(EXTRA_ERROR, message.take(500)),
        )
        finish()
    }

    private fun captureSnapshot(view: WebView, currentUrl: String) {
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
                cookieHeader = cookieHeader,
                localStorageJson = localStorage,
                userAgent = view.settings.userAgentString,
            )
        }
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
        if (::webView.isInitialized) {
            val currentUrl =
                webView.url ?: intent.getStringExtra(EXTRA_URL).orEmpty()
            if (currentUrl.isNotBlank()) {
                captureSnapshot(webView, currentUrl)
            }
            CookieManager.getInstance().flush()
        }
        setResult(RESULT_OK)
        finish()
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            val currentUrl =
                webView.url ?: intent.getStringExtra(EXTRA_URL).orEmpty()
            NetworkBrowserSnapshotStore.update(
                context = this,
                currentUrl = currentUrl,
                title = webView.title,
                cookieHeader = currentUrl.takeIf(String::isNotBlank)?.let { url ->
                    CookieManager.getInstance().getCookie(url)
                },
                userAgent = webView.settings.userAgentString,
            )
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
    }
}
