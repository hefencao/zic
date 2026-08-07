package dev.zic.network

import java.io.IOException
import java.util.Locale
import okhttp3.Interceptor
import okhttp3.Response

/** A response that requires the visible shared browser to renew site state. */
class SourceVerificationRequiredException(
    val requestUrl: String,
    val statusCode: Int,
    val clearanceCookiePresent: Boolean = false,
) : IOException(
    "Cloudflare verification required for $requestUrl (HTTP $statusCode; " +
        "cf_clearance=${if (clearanceCookiePresent) "present" else "absent"})",
)

/**
 * Classifies only responses that carry evidence of an interactive Cloudflare
 * challenge. HTTP status or the Cloudflare server header alone are not enough:
 * ordinary origin/access failures must remain ordinary source failures.
 */
internal fun isCloudflareVerificationResponse(
    statusCode: Int,
    mitigatedHeader: String?,
    serverHeader: String?,
    bodyText: String,
): Boolean {
    if (statusCode !in CLOUDFLARE_STATUS_CODES) return false
    if (mitigatedHeader?.equals("challenge", ignoreCase = true) == true) {
        return true
    }
    val body = bodyText.lowercase(Locale.US)
    val strongChallengeMarker = body.contains("challenge-platform") ||
        body.contains("cf-chl-") ||
        body.contains("cdn-cgi/challenge-platform")
    if (strongChallengeMarker) return true

    // "Just a moment" is a title, not a protocol marker. Require separate
    // Cloudflare branding before asking the user to verify in a browser.
    if (!body.contains("just a moment")) return false
    val server = serverHeader?.trim()?.lowercase(Locale.US)
    val cloudflareServer = server in CLOUDFLARE_SERVERS
    val cloudflareBranding = body.contains("cloudflare") ||
        body.contains("cdn-cgi/")
    return cloudflareServer || cloudflareBranding
}

/**
 * Detects a Cloudflare browser challenge and returns control to the host UI.
 *
 * A runtime interceptor must not create a hidden WebView: the user cannot
 * interact with it, it occupies the plugin invocation permit, and its wait can
 * race the host timeout. The App opens the shared visible source browser after
 * the runtime maps this typed failure to `source-verification-required`.
 */
class AndroidCloudflareInterceptor(
    @Suppress("UNUSED_PARAMETER") context: android.content.Context,
    @Suppress("UNUSED_PARAMETER") defaultUserAgentProvider: () -> String,
    private val clearanceCookiePresent: (okhttp3.HttpUrl) -> Boolean = { false },
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        val body = if (response.code in CLOUDFLARE_STATUS_CODES) {
            runCatching { response.peekBody(CLOUDFLARE_BODY_LIMIT).string() }
                .getOrDefault("")
        } else {
            ""
        }
        val verificationRequired = isCloudflareVerificationResponse(
            statusCode = response.code,
            mitigatedHeader = response.header("cf-mitigated"),
            serverHeader = response.header("Server"),
            bodyText = body,
        )
        if (!verificationRequired) return response
        val requestUrl = response.request.url.toString()
        val statusCode = response.code
        val clearancePresent = clearanceCookiePresent(response.request.url)
        response.close()
        throw SourceVerificationRequiredException(
            requestUrl = requestUrl,
            statusCode = statusCode,
            clearanceCookiePresent = clearancePresent,
        )
    }
}

private const val CLOUDFLARE_BODY_LIMIT = 128L * 1024L
private val CLOUDFLARE_STATUS_CODES = setOf(403, 503)
private val CLOUDFLARE_SERVERS = setOf("cloudflare", "cloudflare-nginx")
