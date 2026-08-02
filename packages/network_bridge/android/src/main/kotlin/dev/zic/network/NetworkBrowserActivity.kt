package dev.zic.network

import android.app.Activity
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
            finish()
            return
        }
        NetworkBrowserSnapshotStore.begin(this, url)
        webView = WebView(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            settings.javaScriptEnabled = true
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
    }

    private fun captureSnapshot(view: WebView, currentUrl: String) {
        val cookieHeader = CookieManager.getInstance().getCookie(currentUrl)
        NetworkBrowserSnapshotStore.update(
            context = this,
            currentUrl = currentUrl,
            title = view.title,
            cookieHeader = cookieHeader,
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
            )
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
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
            )
            CookieManager.getInstance().flush()
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }

    companion object {
        const val EXTRA_URL = "url"
    }
}
