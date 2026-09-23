package dev.zic.mihonruntime

import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.UnknownHostException
import java.net.URL
import java.net.URLEncoder
import java.util.Locale
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.ConcurrentHashMap
import okhttp3.Dns
import org.json.JSONObject

class FallbackDns : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        require(hostname.isNotBlank()) { "hostname is blank" }
        var systemFailure: Throwable? = null
        try {
            val systemAddresses = distinctAddresses(Dns.SYSTEM.lookup(hostname))
            if (systemAddresses.isNotEmpty()) return systemAddresses
        } catch (error: Throwable) {
            systemFailure = error
        }
        val fallback = resolvePublicAddresses(hostname)
        if (fallback.isNotEmpty()) return fallback
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
private const val PUBLIC_DNS_TIMEOUT_MILLIS = 800
private const val DOH_TIMEOUT_MILLIS = 1_000
private val dnsCache = ConcurrentHashMap<String, DnsCacheEntry>()

private fun resolvePublicAddresses(hostname: String): List<InetAddress> {
    if (!isPublicHostname(hostname)) return emptyList()
    val key = hostname.lowercase(Locale.US)
    val now = System.nanoTime()
    dnsCache[key]?.takeIf { it.expiresAtNanos - now > 0 }?.let {
        return it.addresses
    }
    val dnsServers = listOf("223.5.5.5", "119.29.29.29", "1.1.1.1")
    dnsServers.forEach { server ->
        val addresses = interleaveAddressFamilies(
            queryPublicDns(hostname, server, 1),
            queryPublicDns(hostname, server, 28),
        )
        if (addresses.isNotEmpty()) {
            return cacheDnsAddresses(key, addresses)
        }
    }
    val encoded = URLEncoder.encode(hostname, "UTF-8")
    val endpoints = listOf(
        "https://dns.alidns.com/resolve",
        "https://doh.pub/dns-query",
    )
    endpoints.forEach { endpoint ->
        val addresses = interleaveAddressFamilies(
            queryDoh("$endpoint?name=$encoded&type=A"),
            queryDoh("$endpoint?name=$encoded&type=AAAA"),
        )
        if (addresses.isNotEmpty()) {
            return cacheDnsAddresses(key, addresses)
        }
    }
    return emptyList()
}

private fun cacheDnsAddresses(key: String, addresses: List<InetAddress>): List<InetAddress> {
    val ordered = distinctAddresses(addresses)
    dnsCache[key] = DnsCacheEntry(
        ordered,
        System.nanoTime() + DNS_CACHE_NANOS,
    )
    return ordered
}

private fun queryPublicDns(
    hostname: String,
    server: String,
    recordType: Int,
): List<InetAddress> {
    val queryId = ThreadLocalRandom.current().nextInt(0x10000)
    val query = buildDnsQuery(hostname, queryId, recordType) ?: return emptyList()
    return runCatching {
        DatagramSocket().use { socket ->
            socket.soTimeout = PUBLIC_DNS_TIMEOUT_MILLIS
            socket.send(
                DatagramPacket(
                    query,
                    query.size,
                    InetAddress.getByName(server),
                    53,
                ),
            )
            val response = ByteArray(2048)
            val packet = DatagramPacket(response, response.size)
            socket.receive(packet)
            parseDnsResponse(response.copyOf(packet.length), queryId, recordType)
        }
    }.getOrDefault(emptyList())
}

private fun buildDnsQuery(
    hostname: String,
    queryId: Int,
    recordType: Int,
): ByteArray? {
    if (recordType != 1 && recordType != 28) return null
    val labels = hostname.trimEnd('.').split('.')
    if (labels.isEmpty() || labels.any { it.isEmpty() || it.length > 63 }) return null
    val query = ArrayList<Byte>(hostname.length + 18)
    fun addShort(value: Int) {
        query += ((value ushr 8) and 0xff).toByte()
        query += (value and 0xff).toByte()
    }
    addShort(queryId)
    addShort(0x0100)
    addShort(1)
    addShort(0)
    addShort(0)
    addShort(0)
    labels.forEach { label ->
        val bytes = label.toByteArray(Charsets.US_ASCII)
        query += bytes.size.toByte()
        query.addAll(bytes.toList())
    }
    query += 0
    addShort(recordType)
    addShort(1)
    return query.toByteArray()
}

private fun parseDnsResponse(
    response: ByteArray,
    queryId: Int,
    recordType: Int,
): List<InetAddress> {
    if (response.size < 12 || readDnsShort(response, 0) != queryId) return emptyList()
    val flags = readDnsShort(response, 2)
    if (flags and 0x8000 == 0 || flags and 0x000f != 0) return emptyList()
    val questionCount = readDnsShort(response, 4)
    val answerCount = readDnsShort(response, 6)
    var offset = 12
    repeat(questionCount) {
        offset = skipDnsName(response, offset) ?: return emptyList()
        if (offset + 4 > response.size) return emptyList()
        offset += 4
    }
    val addresses = LinkedHashMap<String, InetAddress>()
    repeat(answerCount) {
        offset = skipDnsName(response, offset) ?: return addresses.values.toList()
        if (offset + 10 > response.size) return addresses.values.toList()
        val type = readDnsShort(response, offset)
        val dnsClass = readDnsShort(response, offset + 2)
        val length = readDnsShort(response, offset + 8)
        offset += 10
        if (offset + length > response.size) return addresses.values.toList()
        val expectedLength = if (recordType == 1) 4 else 16
        if (type == recordType && dnsClass == 1 && length == expectedLength) {
            InetAddress.getByAddress(response.copyOfRange(offset, offset + length))
                .takeIf(::isPublicAddress)
                ?.let { address ->
                    address.hostAddress?.let { key -> addresses[key] = address }
                }
        }
        offset += length
    }
    return addresses.values.toList()
}

private fun readDnsShort(bytes: ByteArray, offset: Int): Int =
    ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

private fun skipDnsName(bytes: ByteArray, start: Int): Int? {
    var offset = start
    while (offset < bytes.size) {
        val length = bytes[offset].toInt() and 0xff
        if (length == 0) return offset + 1
        if (length and 0xc0 == 0xc0) {
            return if (offset + 1 < bytes.size) offset + 2 else null
        }
        if (length > 63 || offset + 1 + length > bytes.size) return null
        offset += 1 + length
    }
    return null
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
            ?.let { address ->
                address.hostAddress?.let { key -> result[key] = address }
            }
    }
    return result.values.toList()
}

private fun queryDoh(endpoint: String): List<InetAddress> {
    val connection = URL(endpoint).openConnection() as HttpURLConnection
    connection.connectTimeout = DOH_TIMEOUT_MILLIS
    connection.readTimeout = DOH_TIMEOUT_MILLIS
    connection.setRequestProperty("Accept", "application/dns-json")
    return try {
        if (connection.responseCode !in 200..299) {
            emptyList()
        } else {
            parseDnsJson(
                connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() },
            )
        }
    } catch (_: Throwable) {
        emptyList()
    } finally {
        connection.disconnect()
    }
}

private fun interleaveAddressFamilies(
    ipv4: List<InetAddress>,
    ipv6: List<InetAddress>,
): List<InetAddress> {
    val result = ArrayList<InetAddress>(ipv4.size + ipv6.size)
    val count = maxOf(ipv4.size, ipv6.size)
    repeat(count) { index ->
        if (index < ipv4.size) result += ipv4[index]
        if (index < ipv6.size) result += ipv6[index]
    }
    return distinctAddresses(result)
}

private fun distinctAddresses(addresses: List<InetAddress>): List<InetAddress> =
    addresses.distinctBy(InetAddress::getHostAddress)

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
