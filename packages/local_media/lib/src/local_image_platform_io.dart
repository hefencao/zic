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
  return picked == null ? null : _selectionFromScopedDirectory(picked);
}

Future<LocalImageDirectorySelection> refreshLocalImageDirectory(
  String directoryId,
) async {
  final normalized = directoryId.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(directoryId, 'directoryId', 'must not be empty');
  }
  final uri = Uri.tryParse(normalized);
  if (Platform.isAndroid && uri?.scheme.toLowerCase() == 'content') {
    final refreshed = await _androidBridge.scanImageDirectory(normalized);
    return _selectionFromScopedDirectory(refreshed);
  }
  final scan = await listLocalImageDirectory(normalized);
  return LocalImageDirectorySelection(
    directoryId: normalized,
    displayName: _directoryDisplayName(normalized),
    scan: scan,
  );
}

LocalImageDirectorySelection _selectionFromScopedDirectory(
  LocalMediaDirectory directory,
) {
  final images = <LocalImageFile>[];
  for (final document in directory.documents) {
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
    directoryId: directory.treeUri,
    displayName: directory.displayName,
    scan: LocalImageDirectoryScan(
      images: images,
      scannedFiles: directory.scannedFiles,
      unreadableFiles: directory.unreadableFiles,
      headerRecognizedFiles: directory.headerRecognizedFiles,
      metadataRecognizedFiles: directory.metadataRecognizedFiles,
    ),
  );
}

String _directoryDisplayName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = trimmed.lastIndexOf('/');
  final name = slash < 0 ? trimmed : trimmed.substring(slash + 1);
  return name.trim().isEmpty ? '本地图片文件夹' : name;
}

Future<LocalImageSourceResponse> openLocalImageSource(
  String sourceId, {
  int start = 0,
  int? endExclusive,
  String? expectedRevision,
}) async {
  if (start < 0 || (endExclusive != null && endExclusive < start)) {
    throw ArgumentError('invalid local image byte range');
  }
  final uri = Uri.tryParse(sourceId);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (Platform.isAndroid && scheme == 'content') {
    final response = await _androidBridge.openDocument(
      sourceId,
      start: start,
      endExclusive: endExclusive,
      expectedRevision: expectedRevision,
    );
    return LocalImageSourceResponse(
      bytes: response.bytes,
      rangeStart: response.rangeStart,
      totalLength: response.totalLength,
      revision: response.revision,
      rangeSupported: response.rangeSupported,
      partial: response.partial,
      close: response.close,
    );
  }
  final file = switch (scheme) {
    'file' => File.fromUri(uri!),
    '' => File(sourceId),
    _ => throw FileSystemException(
        '不支持的本地图片来源协议',
        sourceId,
      ),
  };
  if (!file.existsSync()) {
    throw FileSystemException('本地图片不存在', file.path);
  }
  final length = file.lengthSync();
  final modified = file.lastModifiedSync();
  final revision = '$length:${modified.microsecondsSinceEpoch}:${file.path}';
  final rangeRequested = start > 0 || endExclusive != null;
  final canServeRange = rangeRequested &&
      (expectedRevision == null || expectedRevision == revision);
  final rangeStart = canServeRange ? start : 0;
  final boundedEnd = canServeRange
      ? (endExclusive == null
          ? length
          : endExclusive.clamp(rangeStart, length).toInt())
      : length;
  return LocalImageSourceResponse(
    bytes: _readLocalFileChunks(file, rangeStart, boundedEnd),
    rangeStart: rangeStart,
    totalLength: length,
    revision: revision,
    rangeSupported: true,
    partial: canServeRange,
    close: () async {},
  );
}

Stream<List<int>> _readLocalFileChunks(
  File file,
  int start,
  int endExclusive,
) async* {
  const chunkBytes = 1024 * 1024;
  final reader = file.openSync();
  try {
    reader.setPositionSync(start);
    var remaining = endExclusive - start;
    while (remaining > 0) {
      final chunk = reader.readSync(
        remaining < chunkBytes ? remaining : chunkBytes,
      );
      if (chunk.isEmpty) break;
      remaining -= chunk.length;
      yield chunk;
    }
  } finally {
    reader.closeSync();
  }
}

Future<Uint8List?> readLocalImageThumbnail(
  String sourceId, {
  int maxWidth = 512,
  int maxHeight = 768,
}) async {
  final uri = Uri.tryParse(sourceId);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (!Platform.isAndroid || scheme != 'content') {
    return null;
  }
  return _androidBridge.readDocumentThumbnail(
    sourceId,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
}

Future<Uint8List> readLocalImageSource(String sourceId) async {
  final uri = Uri.tryParse(sourceId);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (Platform.isAndroid && scheme == 'content') {
    return _androidBridge.readDocument(sourceId);
  }
  if (scheme == 'file') {
    return File.fromUri(uri!).readAsBytesSync();
  }
  if (scheme.isNotEmpty) {
    throw FileSystemException('不支持的本地图片来源协议', sourceId);
  }
  return File(sourceId).readAsBytesSync();
}

String? localImageFilePath(String sourceId) {
  final uri = Uri.tryParse(sourceId);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (scheme == 'content') {
    return null;
  }
  if (scheme == 'file') {
    return File.fromUri(uri!).path;
  }
  if (scheme.isEmpty) {
    return sourceId;
  }
  return null;
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
