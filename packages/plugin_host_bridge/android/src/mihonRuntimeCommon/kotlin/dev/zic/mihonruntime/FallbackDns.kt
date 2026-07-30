package dev.zic.mihonruntime

import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.UnknownHostException
import java.net.URL
import java.net.URLEncoder
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import okhttp3.Dns
import org.json.JSONObject

class FallbackDns : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        require(hostname.isNotBlank()) { "hostname is blank" }
        var systemFailure: Throwable? = null
        try {
            val addresses = Dns.SYSTEM.lookup(hostname)
            if (addresses.isNotEmpty()) return preferIpv4(addresses)
        } catch (error: Throwable) {
            systemFailure = error
        }
        val fallback = resolvePublicAddresses(hostname)
        if (fallback.isNotEmpty()) return preferIpv4(fallback)
        throw UnknownHostException("No DNS answer for $hostname").apply {
            if (systemFailure != null) initCause(systemFailure)
        }
    }
}

private data class DnsCacheEntry(
    val addresses: List<InetAddress>,
    val expiresAtNanos: Long,
)

private const val DNS_CACHE_NANOS = 5L * 60L * 1_000_000_000L
private const val DOH_TIMEOUT_MILLIS = 1_500
private val dnsCache = ConcurrentHashMap<String, DnsCacheEntry>()

private fun resolvePublicAddresses(hostname: String): List<InetAddress> {
    if (!isPublicHostname(hostname)) return emptyList()
    val key = hostname.lowercase(Locale.US)
    val now = System.nanoTime()
    dnsCache[key]?.takeIf { it.expiresAtNanos - now > 0 }?.let {
        return it.addresses
    }
    val encoded = URLEncoder.encode(hostname, "UTF-8")
    val endpoints = listOf(
        "https://cloudflare-dns.com/dns-query?name=$encoded&type=A",
        "https://dns.alidns.com/resolve?name=$encoded&type=A",
        "https://doh.pub/dns-query?name=$encoded&type=A",
        "https://dns.google/resolve?name=$encoded&type=A",
    )
    endpoints.forEach { endpoint ->
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        connection.connectTimeout = DOH_TIMEOUT_MILLIS
        connection.readTimeout = DOH_TIMEOUT_MILLIS
        connection.setRequestProperty("Accept", "application/dns-json")
        val addresses = runCatching {
            if (connection.responseCode !in 200..299) {
                emptyList()
            } else {
                parseDnsJson(
                    connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() },
                )
            }
        }.getOrDefault(emptyList())
        connection.disconnect()
        if (addresses.isNotEmpty()) {
            val ordered = preferIpv4(addresses)
            dnsCache[key] = DnsCacheEntry(
                ordered,
                System.nanoTime() + DNS_CACHE_NANOS,
            )
            return ordered
        }
    }
    return emptyList()
}

private fun parseDnsJson(raw: String): List<InetAddress> {
    val answers = runCatching { JSONObject(raw).optJSONArray("Answer") }.getOrNull()
        ?: return emptyList()
    val result = LinkedHashMap<String, InetAddress>()
    repeat(answers.length()) { index ->
        val answer = answers.optJSONObject(index) ?: return@repeat
        if (answer.optInt("type") !in setOf(1, 28)) return@repeat
        val value = answer.optString("data").trim()
        if (!looksLikeNumericAddress(value)) return@repeat
        runCatching { InetAddress.getByName(value) }.getOrNull()
            ?.takeIf(::isPublicAddress)
            ?.let { result[it.hostAddress] = it }
    }
    return result.values.toList()
}

private fun preferIpv4(addresses: List<InetAddress>): List<InetAddress> =
    addresses.distinctBy(InetAddress::getHostAddress)
        .sortedBy { if (it.address.size == 4) 0 else 1 }

private fun isPublicHostname(hostname: String): Boolean =
    hostname.contains('.') &&
        !hostname.equals("localhost", true) &&
        !hostname.endsWith(".local", true) &&
        !looksLikeNumericAddress(hostname)

private fun isPublicAddress(address: InetAddress): Boolean =
    !address.isAnyLocalAddress &&
        !address.isLoopbackAddress &&
        !address.isLinkLocalAddress &&
        !address.isSiteLocalAddress &&
        !address.isMulticastAddress

private fun looksLikeNumericAddress(value: String): Boolean =
    value.isNotBlank() && value.all { character ->
        character.isDigit() ||
            character in setOf('.', ':') ||
            character.lowercaseChar() in 'a'..'f'
    }
