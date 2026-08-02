package dev.zic.network

import android.content.Context
import java.io.File
import java.net.URI
import org.json.JSONObject

/**
 * Process-safe handoff for the source browser result.
 *
 * The visible browser and Flutter MethodChannel live in the App process.
 * Isolated source runtimes use their own WebView data directory and import
 * this snapshot into their process-local CookieJar. SharedPreferences keeps a
 * process-local cache and is therefore unsuitable for this handoff. A same-directory temporary file + rename keeps readers on
 * either the previous or the complete next snapshot.
 */
internal object NetworkBrowserSnapshotStore {
    private const val FILE_NAME = "zic_network_browser_snapshot.json"
    private const val KEY_REQUESTED_URL = "requestedUrl"
    private const val KEY_CURRENT_URL = "currentUrl"
    private const val KEY_TITLE = "title"
    private const val KEY_COOKIE_HEADER = "cookieHeader"
    private const val KEY_LOCAL_STORAGE = "localStorage"
    private const val KEY_UPDATED_AT = "updatedAt"
    private const val MAX_AGE_MILLIS = 30L * 60L * 1000L

    fun begin(context: Context, requestedUrl: String) {
        write(
            context,
            JSONObject()
                .put(KEY_REQUESTED_URL, requestedUrl)
                .put(KEY_UPDATED_AT, System.currentTimeMillis()),
        )
    }

    fun update(
        context: Context,
        currentUrl: String,
        title: String?,
        cookieHeader: String?,
        localStorageJson: String? = null,
    ) {
        val snapshot = readObject(context) ?: JSONObject()
        snapshot
            .put(KEY_CURRENT_URL, currentUrl)
            .put(KEY_TITLE, title.orEmpty())
            .put(KEY_COOKIE_HEADER, cookieHeader.orEmpty())
            .put(KEY_UPDATED_AT, System.currentTimeMillis())
        if (localStorageJson != null) {
            snapshot.put(KEY_LOCAL_STORAGE, localStorageJson)
        }
        write(context, snapshot)
    }

    fun read(context: Context, expectedUrl: String): Map<String, Any?>? {
        val snapshot = readObject(context) ?: return null
        val updatedAt = snapshot.optLong(KEY_UPDATED_AT, 0L)
        if (updatedAt <= 0L || System.currentTimeMillis() - updatedAt > MAX_AGE_MILLIS) {
            return null
        }
        val requestedUrl = snapshot.optString(KEY_REQUESTED_URL).takeIf(String::isNotBlank)
            ?: return null
        val requestedHost = runCatching { URI(requestedUrl).host.orEmpty() }.getOrDefault("")
        val expectedHost = runCatching { URI(expectedUrl).host.orEmpty() }.getOrDefault("")
        if (requestedHost.isBlank() || expectedHost.isBlank() ||
            !sameSiteHost(requestedHost, expectedHost)
        ) {
            return null
        }
        val currentUrl = snapshot.optString(KEY_CURRENT_URL).ifBlank { requestedUrl }
        val currentHost = runCatching { URI(currentUrl).host.orEmpty() }.getOrDefault("")
        if (currentHost.isBlank() || !sameSiteHost(requestedHost, currentHost)) {
            return null
        }
        return mapOf(
            "currentUrl" to currentUrl,
            "title" to snapshot.optString(KEY_TITLE),
            "cookies" to parseCookieHeader(snapshot.optString(KEY_COOKIE_HEADER)),
            "localStorage" to parseLocalStorage(snapshot.optString(KEY_LOCAL_STORAGE)),
        )
    }

    private fun readObject(context: Context): JSONObject? = runCatching {
        val file = snapshotFile(context)
        if (!file.isFile) return@runCatching null
        JSONObject(file.readText())
    }.getOrNull()

    private fun write(context: Context, snapshot: JSONObject) {
        val target = snapshotFile(context)
        target.parentFile?.mkdirs()
        val pending = File(target.parentFile, "$FILE_NAME.pending")
        pending.writeText(snapshot.toString())
        if (!pending.renameTo(target)) {
            target.writeText(snapshot.toString())
            pending.delete()
        }
    }

    private fun snapshotFile(context: Context): File = File(context.filesDir, FILE_NAME)

    private fun parseLocalStorage(raw: String): Map<String, String> {
        if (raw.isBlank()) return emptyMap()
        return runCatching {
            val value = JSONObject(raw)
            buildMap {
                value.keys().forEach { key ->
                    val item = value.opt(key)
                    if (item != null && item !== JSONObject.NULL) {
                        put(key, item.toString())
                    }
                }
            }
        }.getOrDefault(emptyMap())
    }

    private fun parseCookieHeader(header: String): Map<String, String> =
        header.split(';').mapNotNull { part ->
            val separator = part.indexOf('=')
            if (separator <= 0) return@mapNotNull null
            val name = part.substring(0, separator).trim()
            val value = part.substring(separator + 1).trim()
            if (name.isEmpty()) null else name to value
        }.toMap()

    private fun sameSiteHost(left: String, right: String): Boolean {
        val a = left.lowercase().trimEnd('.')
        val b = right.lowercase().trimEnd('.')
        return a == b || a.endsWith(".$b") || b.endsWith(".$a")
    }
}
