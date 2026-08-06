package dev.zic.network

import android.content.Context
import android.webkit.CookieManager
import java.net.URI

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
    private val importedSnapshotRevisions = mutableMapOf<String, Long>()

    @Synchronized
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
        val revision = (snapshot["updatedAt"] as? Number)?.toLong() ?: return 0
        val host = runCatching { URI(url).host.orEmpty().lowercase() }
            .getOrDefault("")
        if (host.isBlank()) return 0
        val revisionKey = "$host\u0000${expectedUserAgent.orEmpty()}"
        val importedRevision = importedSnapshotRevisions[revisionKey] ?: 0L
        if (revision <= importedRevision) return 0
        @Suppress("UNCHECKED_CAST")
        val cookies = snapshot["cookies"] as? Map<String, String> ?: emptyMap()
        val manager = CookieManager.getInstance()
        var imported = 0
        cookies.forEach { (name, value) ->
            if (name.isNotBlank()) {
                manager.setCookie(url, "$name=$value; Path=/")
                imported++
            }
        }
        if (imported > 0) manager.flush()
        // A browser snapshot is a one-time handoff. Re-importing it before
        // every request overwrites newer cookies received by the runtime and
        // can make a solved Cloudflare challenge fail again later.
        importedSnapshotRevisions[revisionKey] = revision
        return imported
    }
}
