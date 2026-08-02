package dev.zic.network

import java.io.IOException
import java.util.Locale
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Detects a Cloudflare browser challenge and returns control to the host UI.
 *
 * A runtime interceptor must not create a hidden WebView: the user cannot
 * interact with it, it occupies the plugin invocation permit, and its wait can
 * race the host timeout. The App opens the shared visible source browser after
 * the runtime maps this stable failure to `source-verification-required`.
 */
class AndroidCloudflareInterceptor(
    @Suppress("UNUSED_PARAMETER") context: android.content.Context,
    @Suppress("UNUSED_PARAMETER") defaultUserAgentProvider: () -> String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (!response.isCloudflareChallenge()) return response
        response.close()
        throw IOException(
            "Cloudflare verification failed; open the source page in the browser and retry",
        )
    }

    private fun Response.isCloudflareChallenge(): Boolean {
        val server = header("Server")?.lowercase(Locale.US)
        if (code !in CLOUDFLARE_STATUS_CODES || server !in CLOUDFLARE_SERVERS) {
            return false
        }
        if (header("cf-mitigated")?.equals("challenge", ignoreCase = true) == true) {
            return true
        }
        val body = runCatching { peekBody(CLOUDFLARE_BODY_LIMIT).string() }
            .getOrDefault("")
            .lowercase(Locale.US)
        return body.contains("cf-mitigated") ||
            body.contains("challenge-platform") ||
            body.contains("just a moment") ||
            body.contains("cf-chl-")
    }
}

private const val CLOUDFLARE_BODY_LIMIT = 128L * 1024L
private val CLOUDFLARE_STATUS_CODES = setOf(403, 503)
private val CLOUDFLARE_SERVERS = setOf("cloudflare", "cloudflare-nginx")
