package dev.zic.network

import android.content.Context
import android.webkit.CookieManager

/**
 * Imports the latest visible-browser cookies into the current process.
 *
 * Android WebView storage is process-local when multiple WebView processes are
 * used. The shared browser therefore hands off a bounded atomic snapshot, and
 * each HTTP/runtime process imports only a same-site snapshot produced with
 * the exact user agent used by its requests. Cookie values never leave this
 * Android network boundary.
 */
object AndroidBrowserCookieSession {
    fun importCookies(
        context: Context,
        url: String,
        expectedUserAgent: String? = null,
    ): Int {
        val snapshot = NetworkBrowserSnapshotStore.read(
            context.applicationContext,
            url,
            expectedUserAgent = expectedUserAgent,
        ) ?: return 0
        @Suppress("UNCHECKED_CAST")
        val cookies = snapshot["cookies"] as? Map<String, String> ?: return 0
        if (cookies.isEmpty()) return 0
        val manager = CookieManager.getInstance()
        var imported = 0
        cookies.forEach { (name, value) ->
            if (name.isNotBlank()) {
                manager.setCookie(url, "$name=$value; Path=/")
                imported++
            }
        }
        if (imported > 0) manager.flush()
        return imported
    }
}
