package dev.zic.network

import android.content.Context
import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Shared Android cookie adapter for native and Mihon HTTP clients.
 *
 * The visible browser runs in the App process. Before every request this jar
 * imports the latest process-safe browser snapshot for the same site, so a
 * completed Cloudflare challenge is available to the isolated runtime without
 * relying on WebView's process-local CookieManager cache.
 */
class AndroidCookieJar(context: Context) : CookieJar {
    private val application = context.applicationContext
    private val manager: CookieManager
        get() = CookieManager.getInstance()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cookies.forEach { cookie -> manager.setCookie(url.toString(), cookie.toString()) }
        manager.flush()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        importBrowserSnapshot(url)
        return manager.getCookie(url.toString())
            .orEmpty()
            .split(';')
            .map(String::trim)
            .filter(String::isNotEmpty)
            .mapNotNull { value -> Cookie.parse(url, value) }
    }

    private fun importBrowserSnapshot(url: HttpUrl) {
        val snapshot = NetworkBrowserSnapshotStore.read(application, url.toString())
            ?: return
        @Suppress("UNCHECKED_CAST")
        val cookies = snapshot["cookies"] as? Map<String, String> ?: return
        cookies.forEach { (name, value) ->
            if (name.isNotBlank()) {
                manager.setCookie(url.toString(), "$name=$value; Path=/")
            }
        }
        if (cookies.isNotEmpty()) manager.flush()
    }
}
