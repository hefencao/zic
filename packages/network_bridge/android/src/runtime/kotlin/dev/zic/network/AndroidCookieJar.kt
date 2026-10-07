package dev.zic.network

import android.content.Context
import android.webkit.CookieManager
import java.net.URI
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Shared Android cookie adapter for native and Mihon HTTP clients.
 *
 * Runtime HTTP cookies retain their identity and scope synchronously. The
 * Android CookieManager remains a compatibility mirror, but the first request
 * after visible-browser verification does not wait for its asynchronous
 * setCookie() persistence before emitting cf_clearance through OkHttp.
 */
class AndroidCookieJar(
    context: Context,
    private val userAgentProvider: () -> String = { "" },
) : CookieJar {
    companion object {
        @JvmStatic
        fun resetBrowserSnapshotImports() {
            AndroidBrowserCookieSession.resetAllImports()
        }
    }

    private val application = context.applicationContext
    private val manager: CookieManager
        get() = CookieManager.getInstance()
    private data class CookieIdentity(val name: String, val path: String)

    private val memoryByHost = mutableMapOf<String, LinkedHashMap<CookieIdentity, Cookie>>()
    private val importedSnapshotRevisions = mutableMapOf<String, Long>()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        synchronized(this) {
            cookies.forEach { cookie ->
                val memory = memoryByHost.getOrPut(cookie.domain) { linkedMapOf() }
                memory[CookieIdentity(cookie.name, cookie.path)] = cookie
            }
        }
        cookies.forEach { cookie -> manager.setCookie(url.toString(), cookie.toString()) }
        if (cookies.isNotEmpty()) manager.flush()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> = get(url)

    /**
     * Returns the UA captured by the visible same-site browser session.
     * Cookies and this UA come from the same snapshot revision; Mihon must use
     * them together for Cloudflare retries instead of pairing a WebView cookie
     * with the old synthetic OkHttp UA.
     */
    fun browserSessionUserAgent(url: HttpUrl): String? =
        AndroidBrowserCookieSession.readCookies(
            application,
            url.toString(),
            expectedUserAgent = null,
        )?.userAgent?.takeIf(String::isNotBlank)

    fun get(url: HttpUrl): List<Cookie> {
        importBrowserSnapshot(url)
        val merged = mutableListOf<Cookie>()
        val host = hostOf(url)
        val known = synchronized(this) {
            memoryByHost.values.flatMap { it.values }.filter { cookie ->
                host == cookie.domain ||
                    (!cookie.hostOnly && host.endsWith(".${cookie.domain}"))
            }
        }
        val requestPath = url.encodedPath
        val coveredNames = known.filter { cookie ->
            requestPath == cookie.path ||
                (requestPath.startsWith(cookie.path) &&
                    (cookie.path.endsWith("/") ||
                        requestPath.getOrNull(cookie.path.length) == '/'))
        }.mapTo(mutableSetOf()) { it.name }
        val now = System.currentTimeMillis()
        known.filterTo(merged) { it.expiresAt > now && it.matches(url) }
        manager.getCookie(url.toString())
            .orEmpty()
            .split(';')
            .forEach { raw ->
                val pair = cookiePair(raw) ?: return@forEach
                // Cover only known domain/path scope, including expiry/deletion.
                if (pair.first !in coveredNames) {
                    Cookie.parse(url, raw.trim())?.let(merged::add)
                }
            }
        return merged.sortedByDescending { it.path.length }
    }

    private fun importBrowserSnapshot(url: HttpUrl) {
        val snapshot = AndroidBrowserCookieSession.readCookies(
            application,
            url.toString(),
            expectedUserAgent = null,
        ) ?: return
        val host = hostOf(url)
        val revisionKey = "$host\u0000${snapshot.userAgent}"
        synchronized(this) {
            val importedRevision = importedSnapshotRevisions[revisionKey] ?: 0L
            if (snapshot.revision <= importedRevision) return
            val memory = memoryByHost.getOrPut(host) { linkedMapOf() }
            snapshot.cookies.forEach { (name, value) ->
                if (name.isNotBlank()) {
                    // Browser snapshots contain host-scoped name/value pairs.
                    Cookie.parse(url, "$name=$value; Path=/")?.let { cookie ->
                        memory[CookieIdentity(cookie.name, cookie.path)] = cookie
                    }
                    // Best-effort WebView/extension compatibility mirror only.
                    manager.setCookie(url.toString(), "$name=$value; Path=/")
                }
            }
            if (snapshot.cookies.isNotEmpty()) manager.flush()
            importedSnapshotRevisions[revisionKey] = snapshot.revision
        }
    }

    private fun cookiePair(raw: String): Pair<String, String>? {
        val separator = raw.indexOf('=')
        if (separator <= 0) return null
        val name = raw.substring(0, separator).trim()
        val value = raw.substring(separator + 1).trim()
        if (name.isEmpty()) return null
        return name to value
    }

    private fun hostOf(url: HttpUrl): String = runCatching {
        URI(url.toString()).host.orEmpty().lowercase()
    }.getOrDefault("")
}
