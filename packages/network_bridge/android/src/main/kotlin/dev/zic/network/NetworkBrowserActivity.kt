package dev.zic.network

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray

class NetworkBrowserActivity : Activity() {
    private lateinit var webView: WebView
    private val verificationHandler = Handler(Looper.getMainLooper())
    private var cloudflareVerification = false
    private var completing = false
    private var verificationPageResolved: Boolean? = null
    private var navigationGeneration = 0
    private var challengeFreeSinceUptimeMillis: Long? = null

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
            // Snapshot begin must use the effective WebView UA. For Cloudflare
            // that UA is only known after the real WebView has been created.
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
            // Cloudflare clearance is browser-session state. Spoofing the
            // extension/OkHttp UA inside a real WebView can create a UA/TLS
            // fingerprint mismatch and make Turnstile restart near success.
            // Let the visible WebView use its actual platform UA, persist that
            // UA with the cookies, and make the Mihon retry adopt it.
            if (!cloudflareVerification && requestedUserAgent != null) {
                settings.userAgentString = requestedUserAgent
            }
            settings.domStorageEnabled = true
            settings.databaseEnabled = true
            webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView, currentUrl: String, favicon: android.graphics.Bitmap?) {
                    navigationGeneration += 1
                    verificationPageResolved = null
                    challengeFreeSinceUptimeMillis = null
                }

                override fun onPageFinished(view: WebView, currentUrl: String) {
                    captureSnapshot(view, currentUrl)
                    if (!cloudflareVerification) return
                    if (!sameSiteWithRequestedUrl(currentUrl)) {
                        verificationPageResolved = null
                        challengeFreeSinceUptimeMillis = null
                        return
                    }
                    scheduleVerificationProbe(
                        view = view,
                        expectedUrl = currentUrl,
                        expectedGeneration = navigationGeneration,
                        delayMillis = VERIFICATION_INITIAL_SETTLE_MILLIS,
                    )
                }
            }
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }
        NetworkBrowserSnapshotStore.begin(
            this,
            url,
            webView.settings.userAgentString,
        )
        setContentView(webView)
        webView.loadUrl(url)
    }

    private fun scheduleVerificationProbe(
        view: WebView,
        expectedUrl: String,
        expectedGeneration: Int,
        delayMillis: Long = VERIFICATION_PROBE_INTERVAL_MILLIS,
    ) {
        verificationHandler.postDelayed(
            {
                if (isFinishing || isDestroyed || completing) return@postDelayed
                if (expectedGeneration != navigationGeneration) return@postDelayed
                val currentUrl = view.url.orEmpty()
                if (currentUrl.isBlank() || !sameSiteWithRequestedUrl(currentUrl)) {
                    verificationPageResolved = null
                    challengeFreeSinceUptimeMillis = null
                    return@postDelayed
                }
                if (currentUrl != expectedUrl) {
                    verificationPageResolved = null
                    challengeFreeSinceUptimeMillis = null
                    scheduleVerificationProbe(
                        view = view,
                        expectedUrl = currentUrl,
                        expectedGeneration = expectedGeneration,
                    )
                    return@postDelayed
                }
                view.evaluateJavascript(CLOUDFLARE_BROWSER_STATE_PROBE) { raw ->
                    if (isFinishing || isDestroyed || completing) return@evaluateJavascript
                    if (expectedGeneration != navigationGeneration) return@evaluateJavascript
                    val state = parseBrowserVerificationState(raw)
                    if (!state.ready || view.progress < 100) {
                        verificationPageResolved = null
                        challengeFreeSinceUptimeMillis = null
                        scheduleVerificationProbe(view, expectedUrl, expectedGeneration)
                        return@evaluateJavascript
                    }
                    if (state.challengeVisible) {
                        verificationPageResolved = false
                        challengeFreeSinceUptimeMillis = null
                        scheduleVerificationProbe(view, expectedUrl, expectedGeneration)
                        return@evaluateJavascript
                    }
                    val now = SystemClock.uptimeMillis()
                    val clearSince = challengeFreeSinceUptimeMillis ?: now.also {
                        challengeFreeSinceUptimeMillis = it
                    }
                    val stableMillis = now - clearSince
                    if (stableMillis < VERIFICATION_CLEAR_STABLE_MILLIS) {
                        verificationPageResolved = null
                        scheduleVerificationProbe(view, expectedUrl, expectedGeneration)
                        return@evaluateJavascript
                    }
                    verificationPageResolved = true
                    captureSnapshot(view, currentUrl)
                    completeAndFinish()
                }
            },
            delayMillis,
        )
    }

    private fun parseBrowserVerificationState(raw: String): BrowserVerificationState =
        runCatching {
            val value = JSONArray(raw)
            BrowserVerificationState(
                ready = value.optString(0) == "complete",
                challengeVisible = value.optBoolean(1, true),
            )
        }.getOrDefault(
            BrowserVerificationState(
                ready = false,
                challengeVisible = true,
            ),
        )

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
        verificationHandler.removeCallbacksAndMessages(null)
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
        private const val VERIFICATION_INITIAL_SETTLE_MILLIS = 1500L
        private const val VERIFICATION_PROBE_INTERVAL_MILLIS = 500L
        private const val VERIFICATION_CLEAR_STABLE_MILLIS = 3000L
        private const val CLOUDFLARE_BROWSER_STATE_PROBE =
            "(function(){" +
                "var ready=document.readyState==='complete';" +
                "var visible=function(el){if(!el)return false;" +
                    "var s=window.getComputedStyle(el);var r=el.getBoundingClientRect();" +
                    "return s.display!=='none'&&s.visibility!=='hidden'&&" +
                    "parseFloat(s.opacity||'1')>0&&r.width>0&&r.height>0;};" +
                "var selectors=['#challenge-error-title','#challenge-error-text'," +
                    "'#challenge-running','#cf-challenge-running','#challenge-form'," +
                    "'.challenge-form','.cf-turnstile','[id^=\"cf-chl-\"]'," +
                    "'input[name=\"cf-turnstile-response\"]'," +
                    "'iframe[src*=\"challenges.cloudflare.com\"]'," +
                    "'iframe[src*=\"/cdn-cgi/challenge-platform/\"]'];" +
                "var challenge=selectors.some(function(sel){" +
                    "return Array.prototype.some.call(document.querySelectorAll(sel),visible);});" +
                "var title=(document.title||'').toLowerCase();" +
                "if(title.indexOf('just a moment')>=0)challenge=true;" +
                "var body=((document.body&&document.body.innerText)||'').toLowerCase();" +
                "if(body.indexOf('verify you are human')>=0||" +
                    "body.indexOf('performing security verification')>=0||" +
                    "body.indexOf('checking your browser')>=0)challenge=true;" +
                "return [ready,challenge];" +
            "})()"
    }

    private data class BrowserVerificationState(
        val ready: Boolean,
        val challengeVisible: Boolean,
    )
}
