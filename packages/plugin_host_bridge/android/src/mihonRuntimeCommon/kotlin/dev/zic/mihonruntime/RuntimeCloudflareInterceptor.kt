package dev.zic.mihonruntime

import android.content.Context
import dev.zic.network.AndroidCloudflareInterceptor
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Mihon ABI compatibility wrapper for the host-owned Cloudflare detector.
 *
 * The old implementation created a hidden WebView, waited up to thirty
 * seconds, and then threw an untyped IOException. That split challenge
 * classification from the regular NetworkHelper path and could classify the
 * same response differently depending on which compatibility entry an
 * extension used. Both paths now delegate to the single typed detector; the
 * visible App browser remains the only verification UI.
 */
class RuntimeCloudflareInterceptor(
    context: Context,
    defaultUserAgentProvider: () -> String,
) : Interceptor {
    private val delegate = AndroidCloudflareInterceptor(
        context,
        defaultUserAgentProvider,
    )

    override fun intercept(chain: Interceptor.Chain): Response =
        delegate.intercept(chain)
}
