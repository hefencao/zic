package dev.zic.network

import android.content.Context
import android.webkit.CookieManager
import java.net.URI

internal data class BrowserCookieSnapshot(
    val revision: Long,
    val cookies: Map<String, String>,
    val userAgent: String,
)

/**
 * Imports the latest visible-browser cookies into a runtime process.
 *
 * The visible browser and a Mihon runtime live in different processes. The
 * browser snapshot is therefore the handoff authority; WebView CookieManager
 * is only a best-effort mirror inside the receiving process. OkHttp callers
 * must not depend on an asynchronous CookieManager.setCookie() completing
 * before their first retry.
 */
object AndroidBrowserCookieSession {
    private val importedSnapshotRevisions = mutableMapOf<String, Long>()

    @Synchronized
    fun resetAllImports() {
        importedSnapshotRevisions.clear()
    }

    @Synchronized
    fun resetImport(
        url: String,
        expectedUserAgent: String? = null,
    ) {
        val host = runCatching { URI(url).host.orEmpty().lowercase() }
            .getOrDefault("")
        if (host.isBlank()) return
        importedSnapshotRevisions.remove(
            "$host\u0000${expectedUserAgent.orEmpty()}",
        )
    }

    /** Reads a validated same-site snapshot without marking it consumed. */
    internal fun readCookies(
        context: Context,
        url: String,
        expectedUserAgent: String? = null,
    ): BrowserCookieSnapshot? {
        val snapshot = NetworkBrowserSnapshotStore.read(
            context.applicationContext,
            url,
            expectedUserAgent = expectedUserAgent,
        ) ?: return null
        val revision = (snapshot["updatedAt"] as? Number)?.toLong() ?: return null
        @Suppress("UNCHECKED_CAST")
        val cookies = snapshot["cookies"] as? Map<String, String> ?: emptyMap()
        return BrowserCookieSnapshot(
            revision = revision,
            cookies = cookies.filterKeys(String::isNotBlank),
            userAgent = (snapshot["userAgent"] as? String).orEmpty().trim(),
        )
    }

    /**
     * Legacy/process-global import used by Venera. Mihon uses [readCookies]
     * directly from AndroidCookieJar so its first OkHttp retry receives the
     * browser cookies synchronously.
     */
    @Synchronized
    fun importCookies(
        context: Context,
        url: String,
        expectedUserAgent: String? = null,
    ): Int {
        val snapshot = readCookies(context, url, expectedUserAgent) ?: return 0
        val host = runCatching { URI(url).host.orEmpty().lowercase() }
            .getOrDefault("")
        if (host.isBlank()) return 0
        val revisionKey = "$host\u0000${expectedUserAgent.orEmpty()}"
        val importedRevision = importedSnapshotRevisions[revisionKey] ?: 0L
        if (snapshot.revision <= importedRevision) return 0
        val manager = CookieManager.getInstance()
        snapshot.cookies.forEach { (name, value) ->
            manager.setCookie(url, "$name=$value; Path=/")
        }
        if (snapshot.cookies.isNotEmpty()) manager.flush()
        importedSnapshotRevisions[revisionKey] = snapshot.revision
        return snapshot.cookies.size
    }
}
