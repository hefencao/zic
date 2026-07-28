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

typedef LocalImageFileBytesLoader = Future<Uint8List> Function();

final class LocalImageFile {
  const LocalImageFile({
    required this.file,
    required this.format,
    this.displayName,
    this.sourceId,
    this.readBytes,
  });

  final XFile file;
  final LocalImageFormat format;
  final String? displayName;
  final String? sourceId;
  final LocalImageFileBytesLoader? readBytes;
}

final class LocalImageDirectoryScan {
  LocalImageDirectoryScan({
    required List<LocalImageFile> images,
    required this.scannedFiles,
    required this.unreadableFiles,
    this.headerRecognizedFiles = 0,
    this.metadataRecognizedFiles = 0,
  }) : images = List<LocalImageFile>.unmodifiable(images);

  final List<LocalImageFile> images;
  final int scannedFiles;
  final int unreadableFiles;
  final int headerRecognizedFiles;
  final int metadataRecognizedFiles;

  int get unrecognizedFiles {
    final count = scannedFiles - unreadableFiles - images.length;
    return count < 0 ? 0 : count;
  }
}

final class LocalImageDirectorySelection {
  const LocalImageDirectorySelection({
    required this.directoryId,
    required this.displayName,
    required this.scan,
  });

  final String directoryId;
  final String displayName;
  final LocalImageDirectoryScan scan;
}

LocalImageFormat? localImageFormatByName(String name) {
  final normalized = name.trim().toLowerCase();
  for (final format in LocalImageFormat.values) {
    if (format.name == normalized) {
      return format;
    }
  }
  return null;
}

LocalImageFormat? detectLocalImageFormat(
  Uint8List bytes, {
  int? fileLength,
}) {
  // This is deliberately a signature sniffer rather than a container parser.
  // Directory import must admit the same byte streams that the full Flutter or
  // native decoder can validate after selection, without trusting filenames.
  if (_startsWith(
    bytes,
    const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  )) {
    return LocalImageFormat.png;
  }
  if (_startsWith(bytes, const <int>[0xff, 0xd8, 0xff])) {
    return LocalImageFormat.jpeg;
  }
  if (_startsWithAscii(bytes, 'GIF87a') ||
      _startsWithAscii(bytes, 'GIF89a')) {
    return LocalImageFormat.gif;
  }
  if (_asciiAt(bytes, 0, 'RIFF') && _asciiAt(bytes, 8, 'WEBP')) {
    return LocalImageFormat.webp;
  }
  if (_startsWithAscii(bytes, 'BM')) {
    return LocalImageFormat.bmp;
  }
  if (_startsWith(bytes, const <int>[0x49, 0x49, 0x2a, 0x00]) ||
      _startsWith(bytes, const <int>[0x4d, 0x4d, 0x00, 0x2a])) {
    return LocalImageFormat.tiff;
  }
  if (_startsWith(bytes, const <int>[0x00, 0x00, 0x01, 0x00])) {
    return LocalImageFormat.ico;
  }
  if (bytes.length >= 12 && _asciiAt(bytes, 4, 'ftyp')) {
    final brands = <String>{};
    for (var offset = 8; offset + 4 <= bytes.length; offset += 4) {
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
