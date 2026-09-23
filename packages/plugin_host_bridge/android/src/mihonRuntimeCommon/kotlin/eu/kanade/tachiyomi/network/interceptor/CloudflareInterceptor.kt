package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Canonical Mihon ABI shell around ZIC's Cloudflare verification owner.
 *
 * Extensions inspect the default client's interceptor names and move the
 * Cloudflare interceptor to the end of derived clients. The actual challenge
 * policy stays owned by network_bridge and is injected as the delegate.
 */
class CloudflareInterceptor(
    private val delegate: Interceptor,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response =
        delegate.intercept(chain)
}
