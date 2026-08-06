package dev.zic.network

import android.content.Context
import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Shared Android cookie adapter for native and Mihon HTTP clients.
 *
 * The visible browser runs in the App process. Before a request this jar
 * offers the latest process-safe browser snapshot for the same site. Each
 * snapshot revision is imported at most once, so cookies subsequently received
 * by the isolated runtime are not overwritten by an older browser handoff.
 */
class AndroidCookieJar(
    context: Context,
    private val userAgentProvider: () -> String = { "" },
) : CookieJar {
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
        AndroidBrowserCookieSession.importCookies(
            application,
            url.toString(),
            expectedUserAgent = userAgentProvider(),
        )
    }
}
