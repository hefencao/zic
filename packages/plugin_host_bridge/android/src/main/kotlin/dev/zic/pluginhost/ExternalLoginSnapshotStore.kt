package dev.zic.pluginhost

import android.content.Context
import java.net.URI
import org.json.JSONObject

internal object ExternalLoginSnapshotStore {
    private const val PREFS = "zic_external_login_bridge"
    private const val KEY_REQUESTED_URL = "requested_url"
    private const val KEY_CURRENT_URL = "current_url"
    private const val KEY_TITLE = "title"
    private const val KEY_COOKIE_HEADER = "cookie_header"
    private const val KEY_LOCAL_STORAGE = "local_storage"
    private const val KEY_UPDATED_AT = "updated_at"
    private const val MAX_AGE_MILLIS = 30L * 60L * 1000L

    fun begin(context: Context, requestedUrl: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .clear()
            .putString(KEY_REQUESTED_URL, requestedUrl)
            .putLong(KEY_UPDATED_AT, System.currentTimeMillis())
            .apply()
    }

    fun update(
        context: Context,
        currentUrl: String,
        title: String?,
        cookieHeader: String?,
        localStorageJson: String? = null,
    ) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_CURRENT_URL, currentUrl)
            .putString(KEY_TITLE, title.orEmpty())
            .putString(KEY_COOKIE_HEADER, cookieHeader.orEmpty())
            .apply {
                if (localStorageJson != null) {
                    putString(KEY_LOCAL_STORAGE, localStorageJson)
                }
            }
            .putLong(KEY_UPDATED_AT, System.currentTimeMillis())
            .apply()
    }

    fun read(context: Context, expectedUrl: String): Map<String, Any?>? {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val updatedAt = preferences.getLong(KEY_UPDATED_AT, 0L)
        if (updatedAt <= 0L || System.currentTimeMillis() - updatedAt > MAX_AGE_MILLIS) {
            return null
        }
        val requestedUrl = preferences.getString(KEY_REQUESTED_URL, null) ?: return null
        val requestedHost = runCatching { URI(requestedUrl).host.orEmpty() }.getOrDefault("")
        val expectedHost = runCatching { URI(expectedUrl).host.orEmpty() }.getOrDefault("")
        if (requestedHost.isBlank() || expectedHost.isBlank() ||
            !sameSiteHost(requestedHost, expectedHost)
        ) {
            return null
        }
        val currentUrl = preferences.getString(KEY_CURRENT_URL, null) ?: requestedUrl
        val currentHost = runCatching { URI(currentUrl).host.orEmpty() }.getOrDefault("")
        if (currentHost.isBlank() || !sameSiteHost(requestedHost, currentHost)) {
            return null
        }
        return mapOf(
            "currentUrl" to currentUrl,
            "title" to preferences.getString(KEY_TITLE, "").orEmpty(),
            "cookies" to parseCookieHeader(
                preferences.getString(KEY_COOKIE_HEADER, "").orEmpty(),
            ),
            "localStorage" to parseLocalStorage(
                preferences.getString(KEY_LOCAL_STORAGE, "").orEmpty(),
            ),
        )
    }


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
