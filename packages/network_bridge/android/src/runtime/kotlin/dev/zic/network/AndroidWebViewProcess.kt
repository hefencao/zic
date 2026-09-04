package dev.zic.network

import android.os.Build
import android.webkit.WebView

/**
 * Configures process-local WebView storage before any WebView or CookieManager
 * API is touched in a secondary Android process.
 *
 * Android 9+ rejects multiple processes from sharing the default WebView data
 * directory. App main-process browsers keep the default directory; isolated
 * plugin runtimes must call this once, at process bootstrap, with a stable
 * suffix before creating their HTTP adapters.
 */
object AndroidWebViewProcess {
    @JvmStatic
    fun configureDataDirectorySuffix(suffix: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        val normalized = suffix
            .trim()
            .replace(Regex("[^A-Za-z0-9_.-]"), "_")
            .trim('_')
        require(normalized.isNotEmpty()) { "WebView data-directory suffix is empty" }
        try {
            WebView.setDataDirectorySuffix(normalized)
        } catch (_: IllegalStateException) {
            // The suffix is process-global and set-once. When the service is
            // re-created inside a process whose WebView provider is already
            // initialized (client restart loop, engine already booted), the
            // current suffix is already authoritative — throwing here would
            // crash-loop the whole plugin runtime process.
        }
    }
}
