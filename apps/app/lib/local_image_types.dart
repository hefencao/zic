import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

enum LocalImageFormat {
  jpeg,
  png,
  gif,
  webp,
  bmp,
  tiff,
  ico,
  avif,
  heif,
}

extension LocalImageFormatLabel on LocalImageFormat {
  String get label => switch (this) {
        LocalImageFormat.jpeg => 'JPEG',
        LocalImageFormat.png => 'PNG',
        LocalImageFormat.gif => 'GIF',
        LocalImageFormat.webp => 'WebP',
        LocalImageFormat.bmp => 'BMP',
        LocalImageFormat.tiff => 'TIFF',
        LocalImageFormat.ico => 'ICO',
        LocalImageFormat.avif => 'AVIF',
        LocalImageFormat.heif => 'HEIF',
      };

  bool get isWebp => this == LocalImageFormat.webp;
}

final class LocalImageFile {
  const LocalImageFile({
    required this.file,
    required this.format,
  });

  final XFile file;
  final LocalImageFormat format;
}

final class LocalImageDirectoryScan {
  LocalImageDirectoryScan({
    required List<LocalImageFile> images,
    required this.scannedFiles,
    required this.unreadableFiles,
  }) : images = List<LocalImageFile>.unmodifiable(images);

  final List<LocalImageFile> images;
  final int scannedFiles;
  final int unreadableFiles;

  int get unrecognizedFiles {
    final count = scannedFiles - unreadableFiles - images.length;
    return count < 0 ? 0 : count;
  }
}

LocalImageFormat? detectLocalImageFormat(
  Uint8List bytes, {
  int? fileLength,
}) {
  // This function is a format sniffer, not a complete container validator.
  // Directory import must recognize the same files that Flutter/native codecs
  // can subsequently validate, including files with trailing metadata or a
  // non-canonical declared container length. Full decode remains authoritative.
  final totalLength = fileLength == null || fileLength < bytes.length
      ? bytes.length
      : fileLength;

  if (totalLength >= 24 &&
      bytes.length >= 24 &&
      _startsWith(
        bytes,
        const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      ) &&
      _uint32Be(bytes, 8) == 13 &&
      _asciiAt(bytes, 12, 'IHDR') &&
      _uint32Be(bytes, 16) > 0 &&
      _uint32Be(bytes, 20) > 0) {
    return LocalImageFormat.png;
  }
  if (totalLength >= 3 &&
      _startsWith(bytes, const <int>[0xff, 0xd8, 0xff])) {
    return LocalImageFormat.jpeg;
  }
  if (totalLength >= 10 &&
      bytes.length >= 10 &&
      (_startsWithAscii(bytes, 'GIF87a') ||
          _startsWithAscii(bytes, 'GIF89a')) &&
      _uint16Le(bytes, 6) > 0 &&
      _uint16Le(bytes, 8) > 0) {
    return LocalImageFormat.gif;
  }
  if (totalLength >= 16 &&
      bytes.length >= 16 &&
      _asciiAt(bytes, 0, 'RIFF') &&
      _asciiAt(bytes, 8, 'WEBP') &&
      _isAsciiChunkTag(bytes, 12)) {
    return LocalImageFormat.webp;
  }
  if (totalLength >= 14 &&
      _startsWithAscii(bytes, 'BM') &&
      _uint32Le(bytes, 10) >= 14) {
    return LocalImageFormat.bmp;
  }
  if (totalLength >= 4 &&
      (_startsWith(bytes, const <int>[0x49, 0x49, 0x2a, 0x00]) ||
          _startsWith(bytes, const <int>[0x4d, 0x4d, 0x00, 0x2a]))) {
    return LocalImageFormat.tiff;
  }
  if (totalLength >= 6 &&
      _startsWith(bytes, const <int>[0x00, 0x00, 0x01, 0x00]) &&
      _uint16Le(bytes, 4) > 0) {
    return LocalImageFormat.ico;
  }
  if (bytes.length >= 16 &&
      totalLength >= 16 &&
      _uint32Be(bytes, 0) >= 16 &&
      _asciiAt(bytes, 4, 'ftyp')) {
    final brands = <String>{};
    final declaredBoxLength = _uint32Be(bytes, 0);
    final probeLength = declaredBoxLength > 0 && declaredBoxLength < bytes.length
        ? declaredBoxLength
        : bytes.length;
    for (var offset = 8; offset + 4 <= probeLength && offset < 64; offset += 4) {
      brands.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)));
    }
    if (brands.any((brand) => const <String>{'avif', 'avis'}.contains(brand))) {
      return LocalImageFormat.avif;
    }
    if (brands.any(
      (brand) => const <String>{
        'heic',
        'heix',
        'hevc',
        'hevx',
        'heim',
        'heis',
        'mif1',
        'msf1',
      }.contains(brand),
    )) {
      return LocalImageFormat.heif;
    }
  }
  return null;
}

int _uint32Be(Uint8List bytes, int offset) {
  if (offset < 0 || bytes.length < offset + 4) {
    return -1;
  }
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

int _uint16Le(Uint8List bytes, int offset) {
  if (offset < 0 || bytes.length < offset + 2) {
    return -1;
  }
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _uint32Le(Uint8List bytes, int offset) {
  if (offset < 0 || bytes.length < offset + 4) {
    return -1;
  }
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

bool _isAsciiChunkTag(Uint8List bytes, int offset) {
  if (offset < 0 || bytes.length < offset + 4) {
    return false;
  }
  for (var index = 0; index < 4; index++) {
    final value = bytes[offset + index];
    if (value < 0x20 || value > 0x7e) {
      return false;
    }
  }
  return true;
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) {
    return false;
  }
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) {
      return false;
    }
  }
  return true;
}

bool _startsWithAscii(Uint8List bytes, String value) =>
    _asciiAt(bytes, 0, value);

bool _asciiAt(Uint8List bytes, int offset, String value) {
  if (offset < 0 || bytes.length < offset + value.length) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) {
      return false;
    }
  }
  return true;
}
