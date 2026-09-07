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
