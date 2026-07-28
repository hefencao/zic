package dev.zic.localmedia

import java.util.Locale

internal fun resolveImageFormat(
    bytes: ByteArray,
    mimeType: String?,
    displayName: String?,
): ImageFormatResolution? {
    val header = sniffImageFormat(bytes)
    if (header != null) {
        return ImageFormatResolution(header, "header")
    }
    val mime = imageFormatFromMimeType(mimeType)
    if (mime != null) {
        return ImageFormatResolution(mime, "mime")
    }
    val name = imageFormatFromDisplayName(displayName)
    if (name != null) {
        return ImageFormatResolution(name, "name")
    }
    return null
}


internal fun resolveDirectoryCandidate(
    header: ByteArray?,
    mimeType: String?,
    displayName: String?,
): ImageFormatResolution? {
    val resolution = if (header == null) {
        resolveImageFormat(byteArrayOf(), mimeType, displayName)
    } else {
        resolveImageFormat(header, mimeType, displayName)
    } ?: return null
    return if (header == null) {
        resolution.copy(origin = "${resolution.origin}-deferred")
    } else {
        resolution
    }
}

internal data class ImageFormatResolution(
    val format: String,
    val origin: String,
)

internal fun sniffImageFormat(bytes: ByteArray): String? {
    if (bytes.startsWith(byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))) {
        return "png"
    }
    if (bytes.startsWith(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()))) {
        return "jpeg"
    }
    if (bytes.asciiAt(0, "GIF87a") || bytes.asciiAt(0, "GIF89a")) {
        return "gif"
    }
    if (bytes.asciiAt(0, "RIFF") && bytes.asciiAt(8, "WEBP")) {
        return "webp"
    }
    if (bytes.asciiAt(0, "BM")) {
        return "bmp"
    }
    if (bytes.startsWith(byteArrayOf(0x49, 0x49, 0x2a, 0x00)) ||
        bytes.startsWith(byteArrayOf(0x4d, 0x4d, 0x00, 0x2a))) {
        return "tiff"
    }
    if (bytes.startsWith(byteArrayOf(0x00, 0x00, 0x01, 0x00))) {
        return "ico"
    }
    if (bytes.asciiAt(4, "ftyp")) {
        val brands = HashSet<String>()
        var offset = 8
        while (offset + 4 <= bytes.size) {
            brands.add(String(bytes, offset, 4, Charsets.US_ASCII).lowercase(Locale.ROOT))
            offset += 4
        }
        if (brands.any { it == "avif" || it == "avis" }) {
            return "avif"
        }
        if (brands.any {
                it == "heic" || it == "heix" || it == "hevc" || it == "hevx" ||
                    it == "heim" || it == "heis" || it == "mif1" || it == "msf1"
            }) {
            return "heif"
        }
    }
    return null
}

internal fun imageFormatFromMimeType(value: String?): String? {
    val mime = value?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT).orEmpty()
    return when (mime) {
        "image/jpeg", "image/jpg", "image/pjpeg" -> "jpeg"
        "image/png", "image/x-png" -> "png"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        "image/bmp", "image/x-bmp", "image/x-ms-bmp" -> "bmp"
        "image/tiff", "image/x-tiff" -> "tiff"
        "image/x-icon", "image/vnd.microsoft.icon" -> "ico"
        "image/avif" -> "avif"
        "image/heif", "image/heic", "image/heif-sequence", "image/heic-sequence" -> "heif"
        else -> null
    }
}

internal fun imageFormatFromDisplayName(value: String?): String? {
    val name = value?.trim()?.lowercase(Locale.ROOT).orEmpty()
    val extension = name.substringAfterLast('.', missingDelimiterValue = "")
    return when (extension) {
        "jpg", "jpeg", "jpe", "jfif" -> "jpeg"
        "png" -> "png"
        "gif" -> "gif"
        "webp" -> "webp"
        "bmp", "dib" -> "bmp"
        "tif", "tiff" -> "tiff"
        "ico" -> "ico"
        "avif" -> "avif"
        "heif", "heic", "hif" -> "heif"
        else -> null
    }
}

private fun ByteArray.startsWith(signature: ByteArray): Boolean {
    if (size < signature.size) {
        return false
    }
    for (index in signature.indices) {
        if (this[index] != signature[index]) {
            return false
        }
    }
    return true
}

private fun ByteArray.asciiAt(offset: Int, value: String): Boolean {
    if (offset < 0 || size < offset + value.length) {
        return false
    }
    for (index in value.indices) {
        if (this[offset + index].toInt() and 0xff != value[index].code) {
            return false
        }
    }
    return true
}

internal fun naturalCompare(left: String, right: String): Int {
    val a = left.lowercase(Locale.ROOT)
    val b = right.lowercase(Locale.ROOT)
    var ai = 0
    var bi = 0
    while (ai < a.length && bi < b.length) {
        val aDigit = a[ai].isDigit()
        val bDigit = b[bi].isDigit()
        if (aDigit && bDigit) {
            val aStart = ai
            val bStart = bi
            while (ai < a.length && a[ai].isDigit()) ai++
            while (bi < b.length && b[bi].isDigit()) bi++
            val aNumber = a.substring(aStart, ai).trimStart('0')
            val bNumber = b.substring(bStart, bi).trimStart('0')
            val aCanonical = if (aNumber.isEmpty()) "0" else aNumber
            val bCanonical = if (bNumber.isEmpty()) "0" else bNumber
            if (aCanonical.length != bCanonical.length) {
                return aCanonical.length.compareTo(bCanonical.length)
            }
            val numeric = aCanonical.compareTo(bCanonical)
            if (numeric != 0) {
                return numeric
            }
            val rawLength = (ai - aStart).compareTo(bi - bStart)
            if (rawLength != 0) {
                return rawLength
            }
            continue
        }
        val order = a[ai].compareTo(b[bi])
        if (order != 0) {
            return order
        }
        ai++
        bi++
    }
    return a.length.compareTo(b.length)
}
