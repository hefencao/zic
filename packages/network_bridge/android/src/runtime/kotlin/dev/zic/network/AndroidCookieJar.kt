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
 * Runtime HTTP cookies are mirrored synchronously as name/value pairs. The
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
    private val memoryByHost = mutableMapOf<String, LinkedHashMap<String, String>>()
    private val importedSnapshotRevisions = mutableMapOf<String, Long>()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val host = hostOf(url)
        synchronized(this) {
            val memory = memoryByHost.getOrPut(host) { linkedMapOf() }
            cookies.forEach { cookie ->
                rememberCookieString(memory, cookie.toString())
            }
        }
        cookies.forEach { cookie -> manager.setCookie(url.toString(), cookie.toString()) }
        if (cookies.isNotEmpty()) manager.flush()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> = get(url)

    fun get(url: HttpUrl): List<Cookie> {
        importBrowserSnapshot(url)
        val merged = linkedMapOf<String, String>()
        val host = hostOf(url)
        synchronized(this) {
            memoryByHost[host]?.forEach { (name, value) -> merged[name] = value }
        }
        manager.getCookie(url.toString())
            .orEmpty()
            .split(';')
            .forEach { raw ->
                val pair = cookiePair(raw) ?: return@forEach
                merged.putIfAbsent(pair.first, pair.second)
            }
        return merged.mapNotNull { (name, value) ->
            Cookie.parse(url, "$name=$value")
        }
    }

    private fun importBrowserSnapshot(url: HttpUrl) {
        val userAgent = userAgentProvider()
        val snapshot = AndroidBrowserCookieSession.readCookies(
            application,
            url.toString(),
            expectedUserAgent = userAgent,
        ) ?: return
        val host = hostOf(url)
        val revisionKey = "$host\u0000$userAgent"
        synchronized(this) {
            val importedRevision = importedSnapshotRevisions[revisionKey] ?: 0L
            if (snapshot.revision <= importedRevision) return
            val memory = memoryByHost.getOrPut(host) { linkedMapOf() }
            snapshot.cookies.forEach { (name, value) ->
                if (name.isNotBlank()) {
                    memory[name] = value
                    // Best-effort WebView/extension compatibility mirror only.
                    manager.setCookie(url.toString(), "$name=$value; Path=/")
                }
            }
            if (snapshot.cookies.isNotEmpty()) manager.flush()
            importedSnapshotRevisions[revisionKey] = snapshot.revision
        }
    }

    private fun rememberCookieString(
        memory: LinkedHashMap<String, String>,
        rawCookie: String,
    ) {
        val pair = cookiePair(rawCookie.substringBefore(';')) ?: return
        val lower = rawCookie.lowercase()
        if (pair.second.isEmpty() || lower.contains("max-age=0")) {
            memory.remove(pair.first)
        } else {
            memory[pair.first] = pair.second
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
