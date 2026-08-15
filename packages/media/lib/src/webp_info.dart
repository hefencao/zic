import 'dart:convert';
import 'dart:typed_data';

/// Canvas metadata read directly from a complete WebP RIFF container.
final class WebpInfo {
  const WebpInfo({required this.width, required this.height});

  final int width;
  final int height;
}

WebpInfo parseWebpInfo(Uint8List bytes) {
  if (bytes.length < 20 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WEBP') {
    throw const FormatException('missing RIFF/WEBP signature');
  }
  final data = ByteData.sublistView(bytes);
  final declaredLength = data.getUint32(4, Endian.little) + 8;
  if (declaredLength > bytes.length || declaredLength < 20) {
    throw const FormatException('truncated RIFF payload');
  }

  var offset = 12;
  while (offset + 8 <= declaredLength) {
    final tag = ascii.decode(
      bytes.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    final length = data.getUint32(offset + 4, Endian.little);
    final dataOffset = offset + 8;
    final dataEnd = dataOffset + length;
    if (dataEnd > declaredLength || dataEnd > bytes.length) {
      throw const FormatException('truncated WebP chunk');
    }

    if (tag == 'VP8X' && length >= 10) {
      final width = 1 +
          bytes[dataOffset + 4] +
          (bytes[dataOffset + 5] << 8) +
          (bytes[dataOffset + 6] << 16);
      final height = 1 +
          bytes[dataOffset + 7] +
          (bytes[dataOffset + 8] << 8) +
          (bytes[dataOffset + 9] << 16);
      return _checked(width, height);
    }
    if (tag == 'VP8 ' && length >= 10) {
      if (bytes[dataOffset + 3] != 0x9d ||
          bytes[dataOffset + 4] != 0x01 ||
          bytes[dataOffset + 5] != 0x2a) {
        throw const FormatException('invalid VP8 frame header');
      }
      final width = data.getUint16(dataOffset + 6, Endian.little) & 0x3fff;
      final height = data.getUint16(dataOffset + 8, Endian.little) & 0x3fff;
      return _checked(width, height);
    }
    if (tag == 'VP8L' && length >= 5) {
      if (bytes[dataOffset] != 0x2f) {
        throw const FormatException('invalid VP8L frame header');
      }
      final b1 = bytes[dataOffset + 1];
      final b2 = bytes[dataOffset + 2];
      final b3 = bytes[dataOffset + 3];
      final b4 = bytes[dataOffset + 4];
      final width = 1 + b1 + ((b2 & 0x3f) << 8);
      final height = 1 + (b2 >> 6) + (b3 << 2) + ((b4 & 0x0f) << 10);
      return _checked(width, height);
    }
    offset = dataEnd + (length.isOdd ? 1 : 0);
  }
  throw const FormatException('WebP canvas dimensions are missing');
}


/// Reads canvas metadata from an available WebP prefix without requiring the
/// complete RIFF payload or the complete compressed image chunk. VP8/VP8L
/// canvas dimensions live in the first few bytes of the image chunk, so a
/// large declared chunk must not delay geometry until the whole image arrives.
WebpInfo? parseWebpPrefixInfo(Uint8List bytes) {
  if (bytes.length < 20 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WEBP') {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final tag = ascii.decode(
      bytes.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    final length = data.getUint32(offset + 4, Endian.little);
    final dataOffset = offset + 8;
    final dataEnd = dataOffset + length;
    if (tag == 'VP8X' && length >= 10) {
      if (dataOffset + 10 > bytes.length) return null;
      return _checked(
        1 + bytes[dataOffset + 4] +
            (bytes[dataOffset + 5] << 8) +
            (bytes[dataOffset + 6] << 16),
        1 + bytes[dataOffset + 7] +
            (bytes[dataOffset + 8] << 8) +
            (bytes[dataOffset + 9] << 16),
      );
    }
    if (tag == 'VP8 ' && length >= 10) {
      if (dataOffset + 10 > bytes.length) return null;
      if (bytes[dataOffset + 3] != 0x9d ||
          bytes[dataOffset + 4] != 0x01 ||
          bytes[dataOffset + 5] != 0x2a) {
        throw const FormatException('invalid VP8 frame header');
      }
      return _checked(
        data.getUint16(dataOffset + 6, Endian.little) & 0x3fff,
        data.getUint16(dataOffset + 8, Endian.little) & 0x3fff,
      );
    }
    if (tag == 'VP8L' && length >= 5) {
      if (dataOffset + 5 > bytes.length) return null;
      if (bytes[dataOffset] != 0x2f) {
        throw const FormatException('invalid VP8L frame header');
      }
      final b1 = bytes[dataOffset + 1];
      final b2 = bytes[dataOffset + 2];
      final b3 = bytes[dataOffset + 3];
      final b4 = bytes[dataOffset + 4];
      return _checked(
        1 + b1 + ((b2 & 0x3f) << 8),
        1 + (b2 >> 6) + (b3 << 2) + ((b4 & 0x0f) << 10),
      );
    }
    // Unknown chunks cannot be skipped until their complete payload is
    // available. Known canvas-bearing chunks above only need their fixed
    // header bytes, not the whole compressed image payload.
    if (dataEnd > bytes.length) return null;
    offset = dataEnd + (length.isOdd ? 1 : 0);
  }
  return null;
}

bool webpPrefixDeclaresAnimation(Uint8List bytes) {
  if (bytes.length < 30 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WEBP') {
    return false;
  }
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final tag = ascii.decode(bytes.sublist(offset, offset + 4), allowInvalid: true);
    final length = data.getUint32(offset + 4, Endian.little);
    final dataOffset = offset + 8;
    final dataEnd = dataOffset + length;
    if (dataEnd > bytes.length) return false;
    if (tag == 'ANIM') return true;
    if (tag == 'VP8X' && length >= 1 && (bytes[dataOffset] & 0x02) != 0) {
      return true;
    }
    offset = dataEnd + (length.isOdd ? 1 : 0);
  }
  return false;
}

WebpInfo _checked(int width, int height) {
  if (width <= 0 || height <= 0 || width > 16383 || height > 16383) {
    throw const FormatException('invalid WebP canvas dimensions');
  }
  return WebpInfo(width: width, height: height);
}
