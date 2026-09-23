package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Mihon-compatible default User-Agent interceptor.
 *
 * Source-provided User-Agent headers remain authoritative. The default is only
 * filled when the request does not already carry one.
 */
class UserAgentInterceptor(
    private val defaultUserAgentProvider: () -> String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()
        if (!originalRequest.header("User-Agent").isNullOrEmpty()) {
            return chain.proceed(originalRequest)
        }

        val request = originalRequest
            .newBuilder()
            .removeHeader("User-Agent")
            .addHeader("User-Agent", defaultUserAgentProvider())
            .build()
        return chain.proceed(request)
    }
}
