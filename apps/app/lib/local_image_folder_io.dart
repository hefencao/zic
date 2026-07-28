import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'local_image_types.dart';

const _headerProbeBytes = 64;

Future<LocalImageDirectoryScan> listLocalImageDirectory(String path) async {
  final selectedUri = Uri.tryParse(path);
  if (selectedUri != null && selectedUri.scheme.toLowerCase() == 'content') {
    throw FileSystemException(
      '目录选择器返回了 content URI，无法直接枚举；请更新 Android 文件选择器实现',
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
        ),
      )
      .toList(growable: false);
  return LocalImageDirectoryScan(
    images: matches,
    scannedFiles: raw.scannedFiles,
    unreadableFiles: raw.unreadableFiles,
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
          _RawImageMatch(path: entity.path, formatIndex: format.index),
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
  const _RawImageMatch({required this.path, required this.formatIndex});

  final String path;
  final int formatIndex;
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
