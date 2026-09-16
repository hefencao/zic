enum ContentKind { unknown, webp, gif, fallback }

enum EncodedImageKind {
  jpeg,
  png,
  webp,
  gif,
  bmp,
  tiff,
  ico,
  avif,
  heif,
}

const int sniffPrefixLength = 12;
const int encodedImageSniffPrefixLength = 64;

ContentKind sniffContent(List<int> prefix, {bool finalChunk = false}) {
  if (prefix.length >= 12 &&
      _ascii(prefix, 0, 'RIFF') &&
      _ascii(prefix, 8, 'WEBP')) {
    return ContentKind.webp;
  }
  if (prefix.length >= 6 &&
      (_ascii(prefix, 0, 'GIF87a') || _ascii(prefix, 0, 'GIF89a'))) {
    return ContentKind.gif;
  }
  if (prefix.length >= sniffPrefixLength || finalChunk) {
    return ContentKind.fallback;
  }
  return ContentKind.unknown;
}

EncodedImageKind? sniffEncodedImageKind(List<int> prefix) {
  if (_bytes(prefix, 0, const <int>[0xff, 0xd8, 0xff])) {
    return EncodedImageKind.jpeg;
  }
  if (_bytes(
    prefix,
    0,
    const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  )) {
    return EncodedImageKind.png;
  }
  if (_ascii(prefix, 0, 'RIFF') && _ascii(prefix, 8, 'WEBP')) {
    return EncodedImageKind.webp;
  }
  if (_ascii(prefix, 0, 'GIF87a') || _ascii(prefix, 0, 'GIF89a')) {
    return EncodedImageKind.gif;
  }
  if (_bytes(prefix, 0, const <int>[0x42, 0x4d])) {
    return EncodedImageKind.bmp;
  }
  if (_bytes(prefix, 0, const <int>[0x49, 0x49, 0x2a, 0x00]) ||
      _bytes(prefix, 0, const <int>[0x4d, 0x4d, 0x00, 0x2a])) {
    return EncodedImageKind.tiff;
  }
  if (_bytes(prefix, 0, const <int>[0x00, 0x00, 0x01, 0x00])) {
    return EncodedImageKind.ico;
  }
  if (_ascii(prefix, 4, 'ftyp') && prefix.length >= 12) {
    final brands = <String>{_fourCc(prefix, 8)};
    for (var offset = 16; offset + 4 <= prefix.length; offset += 4) {
      brands.add(_fourCc(prefix, offset));
    }
    if (brands.any(const <String>{'avif', 'avis'}.contains)) {
      return EncodedImageKind.avif;
    }
    if (brands.any(
      const <String>{
        'heic',
        'heix',
        'hevc',
        'hevx',
        'heim',
        'heis',
        'mif1',
        'msf1',
      }.contains,
    )) {
      return EncodedImageKind.heif;
    }
  }
  return null;
}

bool hasSupportedEncodedImageSignature(List<int> prefix) =>
    sniffEncodedImageKind(prefix) != null;

({int width, int height})? parseEncodedImageDimensions(
  List<int> prefix, {
  EncodedImageKind? kind,
}) {
  final resolvedKind = kind ?? sniffEncodedImageKind(prefix);
  if (resolvedKind == null) return null;

  int u16be(int offset) => (prefix[offset] << 8) | prefix[offset + 1];
  int u16le(int offset) => prefix[offset] | (prefix[offset + 1] << 8);
  int u32be(int offset) =>
      (prefix[offset] << 24) |
      (prefix[offset + 1] << 16) |
      (prefix[offset + 2] << 8) |
      prefix[offset + 3];
  int i32le(int offset) {
    final value = prefix[offset] |
        (prefix[offset + 1] << 8) |
        (prefix[offset + 2] << 16) |
        (prefix[offset + 3] << 24);
    return value.toSigned(32);
  }

  ({int width, int height})? valid(int width, int height) =>
      width > 0 && height > 0 ? (width: width, height: height) : null;

  switch (resolvedKind) {
    case EncodedImageKind.png:
      if (prefix.length < 24 || !_ascii(prefix, 12, 'IHDR')) return null;
      return valid(u32be(16), u32be(20));
    case EncodedImageKind.gif:
      if (prefix.length < 10) return null;
      return valid(u16le(6), u16le(8));
    case EncodedImageKind.bmp:
      if (prefix.length < 26) return null;
      return valid(i32le(18).abs(), i32le(22).abs());
    case EncodedImageKind.ico:
      if (prefix.length < 8) return null;
      return valid(
        prefix[6] == 0 ? 256 : prefix[6],
        prefix[7] == 0 ? 256 : prefix[7],
      );
    case EncodedImageKind.jpeg:
      if (prefix.length < 4 || prefix[0] != 0xff || prefix[1] != 0xd8) {
        return null;
      }
      var offset = 2;
      while (offset + 1 < prefix.length) {
        if (prefix[offset] != 0xff) {
          offset++;
          continue;
        }
        while (offset < prefix.length && prefix[offset] == 0xff) {
          offset++;
        }
        if (offset >= prefix.length) return null;
        final marker = prefix[offset++];
        if (marker == 0xd8 || marker == 0xd9 || marker == 0x01) {
          continue;
        }
        if (marker == 0xda || offset + 2 > prefix.length) return null;
        final segmentLength = u16be(offset);
        if (segmentLength < 2) return null;
        final isStartOfFrame = marker >= 0xc0 &&
            marker <= 0xcf &&
            marker != 0xc4 &&
            marker != 0xc8 &&
            marker != 0xcc;
        if (isStartOfFrame) {
          if (segmentLength < 7 || offset + 7 > prefix.length) return null;
          return valid(u16be(offset + 5), u16be(offset + 3));
        }
        if (offset + segmentLength > prefix.length) return null;
        offset += segmentLength;
      }
      return null;
    case EncodedImageKind.webp:
    case EncodedImageKind.tiff:
    case EncodedImageKind.avif:
    case EncodedImageKind.heif:
      return null;
  }
}

String _fourCc(List<int> bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4)).toLowerCase();

bool _bytes(List<int> bytes, int offset, List<int> signature) {
  if (offset < 0 || offset + signature.length > bytes.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[offset + i] != signature[i]) return false;
  }
  return true;
}

bool _ascii(List<int> bytes, int offset, String value) {
  if (offset < 0 || offset + value.length > bytes.length) {
    return false;
  }
  for (var i = 0; i < value.length; i++) {
    if (bytes[offset + i] != value.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}
