import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:local_media_bridge/local_media_bridge.dart';

import 'local_image_model.dart';

const _headerProbeBytes = 64;
const _androidBridge = LocalMediaBridge();

bool get prefersScopedLocalImageDirectoryPicker => Platform.isAndroid;

Future<LocalImageDirectorySelection?> pickScopedLocalImageDirectory() async {
  if (!Platform.isAndroid) {
    throw UnsupportedError(
      'scoped-storage 图片文件夹导入仅用于 Android 文档树',
    );
  }
  final picked = await _androidBridge.pickImageDirectory();
  if (picked == null) {
    return null;
  }
  final images = <LocalImageFile>[];
  for (final document in picked.documents) {
    final format = localImageFormatByName(document.format);
    if (format == null) {
      continue;
    }
    final sourceUri = document.sourceUri;
    images.add(
      LocalImageFile(
        file: XFile(sourceUri),
        format: format,
        displayName: document.displayName,
        sourceId: sourceUri,
        byteLength: document.byteLength,
        readBytes: () => _androidBridge.readDocument(sourceUri),
      ),
    );
  }
  return LocalImageDirectorySelection(
    directoryId: picked.treeUri,
    displayName: picked.displayName,
    scan: LocalImageDirectoryScan(
      images: images,
      scannedFiles: picked.scannedFiles,
      unreadableFiles: picked.unreadableFiles,
      headerRecognizedFiles: picked.headerRecognizedFiles,
      metadataRecognizedFiles: picked.metadataRecognizedFiles,
    ),
  );
}

Future<LocalImageDirectoryScan> listLocalImageDirectory(String path) async {
  final selectedUri = Uri.tryParse(path);
  if (selectedUri != null && selectedUri.scheme.toLowerCase() == 'content') {
    throw FileSystemException(
      '目录选择器返回了 content URI；Android 必须通过 scoped document tree 枚举',
      path,
    );
  }
  final directory = Directory(path);
  if (!await directory.exists()) {
    throw FileSystemException('文件夹不存在或当前平台未提供可读取路径', path);
  }

  final raw = await Isolate.run(() => _scanImagePaths(path));
  final matches = raw.matches
      .map(
        (match) => LocalImageFile(
          file: XFile(match.path),
          format: LocalImageFormat.values[match.formatIndex],
          sourceId: match.path,
          byteLength: match.byteLength,
        ),
      )
      .toList(growable: false);
  return LocalImageDirectoryScan(
    images: matches,
    scannedFiles: raw.scannedFiles,
    unreadableFiles: raw.unreadableFiles,
    headerRecognizedFiles: matches.length,
  );
}

Future<_RawImageScan> _scanImagePaths(String path) async {
  final matches = <_RawImageMatch>[];
  var scannedFiles = 0;
  var unreadableFiles = 0;
  await for (final entity in Directory(path).list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) {
      continue;
    }
    scannedFiles++;
    RandomAccessFile? handle;
    try {
      handle = await entity.open();
      final length = await handle.length();
      final prefix = await handle.read(_headerProbeBytes);
      final format = detectLocalImageFormat(
        Uint8List.fromList(prefix),
        fileLength: length,
      );
      if (format != null) {
        matches.add(
          _RawImageMatch(
            path: entity.path,
            formatIndex: format.index,
            byteLength: length,
          ),
        );
      }
    } on FileSystemException {
      unreadableFiles++;
    } on OSError {
      unreadableFiles++;
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } on FileSystemException {
          // Closing a probe must not abort the rest of the directory scan.
        }
      }
    }
  }
  matches.sort((left, right) => _naturalPathCompare(left.path, right.path));
  return _RawImageScan(
    matches: matches,
    scannedFiles: scannedFiles,
    unreadableFiles: unreadableFiles,
  );
}

final class _RawImageScan {
  const _RawImageScan({
    required this.matches,
    required this.scannedFiles,
    required this.unreadableFiles,
  });

  final List<_RawImageMatch> matches;
  final int scannedFiles;
  final int unreadableFiles;
}

final class _RawImageMatch {
  const _RawImageMatch({
    required this.path,
    required this.formatIndex,
    required this.byteLength,
  });

  final String path;
  final int formatIndex;
  final int byteLength;
}

int _naturalPathCompare(String left, String right) {
  final a = left.replaceAll('\\', '/').toLowerCase();
  final b = right.replaceAll('\\', '/').toLowerCase();
  var ai = 0;
  var bi = 0;
  while (ai < a.length && bi < b.length) {
    final aDigit = _isDigit(a.codeUnitAt(ai));
    final bDigit = _isDigit(b.codeUnitAt(bi));
    if (aDigit && bDigit) {
      final aStart = ai;
      final bStart = bi;
      while (ai < a.length && _isDigit(a.codeUnitAt(ai))) {
        ai++;
      }
      while (bi < b.length && _isDigit(b.codeUnitAt(bi))) {
        bi++;
      }
      final aNumber = int.tryParse(a.substring(aStart, ai));
      final bNumber = int.tryParse(b.substring(bStart, bi));
      if (aNumber != null && bNumber != null && aNumber != bNumber) {
        return aNumber.compareTo(bNumber);
      }
      final digitLength = (ai - aStart).compareTo(bi - bStart);
      if (digitLength != 0) {
        return digitLength;
      }
      continue;
    }
    final order = a.codeUnitAt(ai).compareTo(b.codeUnitAt(bi));
    if (order != 0) {
      return order;
    }
    ai++;
    bi++;
  }
  return a.length.compareTo(b.length);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
