enum ContentKind { unknown, webp, gif, fallback }

const int sniffPrefixLength = 12;

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

bool _ascii(List<int> bytes, int offset, String value) {
  if (offset + value.length > bytes.length) {
    return false;
  }
  for (var i = 0; i < value.length; i++) {
    if (bytes[offset + i] != value.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}
