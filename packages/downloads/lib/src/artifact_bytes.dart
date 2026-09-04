import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Byte-level access to one durable artifact record.
///
/// The default implementation serves POSIX files under the store directory;
/// the SAF implementation serves `saf:<treeUri>?path=<relative>` records
/// through a persisted document-tree grant. Index rows never distinguish the
/// two beyond their path scheme.
abstract interface class ArtifactBytes {
  Future<bool> exists(String path);

  Future<int> length(String path);

  /// Streams [start]..[endExclusive) of the artifact as bounded chunks.
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  });

  Future<void> delete(String path);
}

class LocalArtifactBytes implements ArtifactBytes {
  const LocalArtifactBytes();

  @override
  Future<bool> exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.file;

  @override
  Future<int> length(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return 0;
    }
    return File(path).length();
  }

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    final file = File(path);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return;
    }
    final raf = await file.open();
    try {
      var position = start;
      final end = endExclusive ?? await file.length();
      await raf.setPosition(position);
      while (position < end) {
        final chunk = await raf.read(min(end - position, 512 * 1024));
        if (chunk.isEmpty) break;
        position += chunk.length;
        yield chunk;
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await file.delete();
    }
  }
}

/// Minimal SAF transport the app binds at composition time; keeps this
/// package free of any platform channel dependency.
abstract interface class SafTreeIo {
  Future<int?> open(
    String relativePath, {
    SafWriteMode mode,
  });

  Future<Uint8List> read(int handle, int length);

  Future<void> write(int handle, Uint8List bytes);

  Future<int?> length(int handle);

  Future<void> seek(int handle, int position);

  Future<void> close(int handle);

  Future<bool> delete(String relativePath);

  /// Renames a file within the same SAF directory. Implementations should
  /// perform the native provider operation without exposing a partially
  /// written destination.
  Future<bool> rename(String relativePath, String newRelativePath);

  Future<bool> exists(String relativePath);

  Future<List<SafTreeFile>> list(String relativePath);
}

/// Optional provider capability for replacing an existing document without
/// deleting the old authority first. Implementations that cannot provide this
/// guarantee must return false; callers then keep the old binding untouched.
abstract interface class SafTreeAtomicReplace {
  Future<bool> replace(String temporaryPath, String targetPath);
}

final class SafTreeFile {
  const SafTreeFile({
    required this.name,
    required this.isDirectory,
    required this.length,
  });

  final String name;
  final bool isDirectory;
  final int length;
}

enum SafWriteMode { read, writeAppend, writeTruncate }

/// Parses `saf:<encodedTreeUri>?path=<relative>` record paths.
({String treeUri, String relativePath})? parseSafRecordPath(String path) {
  if (!path.startsWith('saf:')) return null;
  final rest = path.substring(4);
  final marker = rest.indexOf('?path=');
  if (marker < 0) return null;
  final treeUri = Uri.decodeComponent(rest.substring(0, marker));
  final relativePath = Uri.decodeComponent(rest.substring(marker + 6));
  if (!_isSafeSafRelativePath(relativePath)) return null;
  return (treeUri: treeUri, relativePath: relativePath);
}

String encodeSafRecordPath({
  required String treeUri,
  required String relativePath,
}) {
  if (treeUri.trim().isEmpty || !_isSafeSafRelativePath(relativePath)) {
    throw ArgumentError.value(relativePath, 'relativePath', 'must be a safe relative path');
  }
  return 'saf:${Uri.encodeComponent(treeUri)}?path=${Uri.encodeComponent(relativePath)}';
}

bool _isSafeSafRelativePath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  final segments = path.split('/');
  return segments.every((segment) => segment.isNotEmpty && segment != '.' && segment != '..');
}

class SafArtifactBytes implements ArtifactBytes {
  SafArtifactBytes(this._io, {this.treeUri});

  final SafTreeIo _io;
  final String? treeUri;

  bool _belongsToThisTree(String path) {
    final parsed = parseSafRecordPath(path);
    return parsed != null && (treeUri == null || parsed.treeUri == treeUri);
  }

  @override
  Future<bool> exists(String path) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || !_belongsToThisTree(path)) return false;
    return _io.exists(parsed.relativePath);
  }

  @override
  Future<int> length(String path) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || !_belongsToThisTree(path)) return 0;
    final handle = await _io.open(parsed.relativePath);
    if (handle == null) return 0;
    try {
      return await _io.length(handle) ?? 0;
    } finally {
      await _io.close(handle);
    }
  }

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || !_belongsToThisTree(path)) return;
    final handle = await _io.open(parsed.relativePath);
    if (handle == null) return;
    try {
      var position = start;
      await _io.seek(handle, position);
      while (endExclusive == null || position < endExclusive) {
        final remaining =
            endExclusive == null ? 512 * 1024 : endExclusive - position;
        final chunk = await _io.read(handle, remaining.clamp(0, 512 * 1024));
        if (chunk.isEmpty) break;
        position += chunk.length;
        yield chunk;
      }
    } finally {
      await _io.close(handle);
    }
  }

  @override
  Future<void> delete(String path) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || !_belongsToThisTree(path)) return;
    await _io.delete(parsed.relativePath);
  }
}

/// Routes artifact operations between local POSIX storage and SAF tree storage
/// based on the record path scheme (`saf:...` vs plain paths).
class CompositeArtifactBytes implements ArtifactBytes {
  const CompositeArtifactBytes({
    this.local = const LocalArtifactBytes(),
    this.saf,
  });

  final ArtifactBytes local;
  final SafArtifactBytes? saf;

  ArtifactBytes? _target(String path) {
    if (path.startsWith('saf:')) return saf;
    return local;
  }

  @override
  Future<bool> exists(String path) async =>
      await _target(path)?.exists(path) ?? false;

  @override
  Future<int> length(String path) async =>
      await _target(path)?.length(path) ?? 0;

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    final target = _target(path);
    if (target == null) return;
    yield* target.readChunks(
      path,
      start: start,
      endExclusive: endExclusive,
    );
  }

  @override
  Future<void> delete(String path) async {
    await _target(path)?.delete(path);
  }
}

/// Copies [sourceFile] into the SAF tree at [relativePath]. The provider is
/// never truncated in place: bytes are committed to a sibling temporary file,
/// then renamed into place after the source has been fully read.
Future<void> copyFileIntoSaf(
  SafTreeIo io,
  File sourceFile,
  String relativePath,
) async {
  await _writeSafAtomically(io, relativePath, (temporaryPath) async {
    final handle = await io.open(
      temporaryPath,
      mode: SafWriteMode.writeTruncate,
    );
    if (handle == null) {
      throw StateError('SAF tree refused create for $temporaryPath');
    }
    try {
      final raf = await sourceFile.open();
      try {
        while (true) {
          final chunk = await raf.read(512 * 1024);
          if (chunk.isEmpty) break;
          await io.write(handle, chunk);
        }
      } finally {
        await raf.close();
      }
    } finally {
      await io.close(handle);
    }
  });
}

/// Writes [bytes] into a committed SAF file without exposing a partially
/// written final path to readers.
Future<void> writeBytesToSaf(
  SafTreeIo io,
  String relativePath,
  Uint8List bytes,
) async {
  await _writeSafAtomically(io, relativePath, (temporaryPath) async {
    final handle = await io.open(
      temporaryPath,
      mode: SafWriteMode.writeTruncate,
    );
    if (handle == null) {
      throw StateError('SAF tree refused create for $temporaryPath');
    }
    try {
      await io.write(handle, bytes);
    } finally {
      await io.close(handle);
    }
  });
}

Future<void> commitSafTemporary(
  SafTreeIo io,
  String temporaryPath,
  String targetPath,
) async {
  if (await io.rename(temporaryPath, targetPath)) return;
  if (io is SafTreeAtomicReplace) {
    final atomic = io as SafTreeAtomicReplace;
    if (await atomic.replace(temporaryPath, targetPath)) return;
    throw StateError(
      'SAF provider cannot atomically replace $targetPath; old authority retained',
    );
  }
  // Test/local adapters predating the capability can still exercise the
  // protocol. Production adapters implement SafTreeAtomicReplace and never
  // enter this delete-then-rename compatibility path.
  if (await io.exists(targetPath)) await io.delete(targetPath);
  if (!await io.rename(temporaryPath, targetPath)) {
    throw StateError('SAF tree refused commit for $targetPath');
  }
}

Future<void> _writeSafAtomically(
  SafTreeIo io,
  String relativePath,
  Future<void> Function(String temporaryPath) write,
) async {
  if (!_isSafeSafRelativePath(relativePath)) {
    throw ArgumentError.value(relativePath, 'relativePath', 'must be safe');
  }
  final temporaryPath =
      '$relativePath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}';
  try {
    await write(temporaryPath);
    await commitSafTemporary(io, temporaryPath, relativePath);
  } finally {
    if (await io.exists(temporaryPath)) {
      await io.delete(temporaryPath);
    }
  }
}

/// Sniffs the image format extension (webp, jpg, png, gif, avif) from header bytes.
/// Falls back to 'bin' on unknown format.
String sniffImageExtensionFromBytes(List<int> header) {
  if (header.length >= 3 &&
      header[0] == 0xff &&
      header[1] == 0xd8 &&
      header[2] == 0xff) {
    return 'jpg';
  }
  if (header.length >= 8 &&
      header[0] == 0x89 &&
      header[1] == 0x50 &&
      header[2] == 0x4e &&
      header[3] == 0x47) {
    return 'png';
  }
  if (header.length >= 12 &&
      header[0] == 0x52 &&
      header[1] == 0x49 &&
      header[2] == 0x46 &&
      header[3] == 0x46 &&
      header[8] == 0x57 &&
      header[9] == 0x45 &&
      header[10] == 0x42 &&
      header[11] == 0x50) {
    return 'webp';
  }
  if (header.length >= 6 &&
      header[0] == 0x47 &&
      header[1] == 0x49 &&
      header[2] == 0x46) {
    return 'gif';
  }
  if (header.length >= 12 &&
      header[4] == 0x66 &&
      header[5] == 0x74 &&
      header[6] == 0x79 &&
      header[7] == 0x70) {
    return 'avif';
  }
  return 'bin';
}

/// Sniffs the image format extension (webp, jpg, png, gif, avif) from the first
/// 32 bytes of [file]. Falls back to 'bin' on failure or unknown format.
Future<String> sniffImageExtension(File file) async {
  try {
    final raf = await file.open(mode: FileMode.read);
    try {
      final header = await raf.read(32);
      return sniffImageExtensionFromBytes(header);
    } finally {
      await raf.close();
    }
  } on Object {
    // Fall back to bin on read errors.
  }
  return 'bin';
}

Future<bool> isHtmlOrTextFile(File file) async {
  try {
    final raf = await file.open(mode: FileMode.read);
    try {
      final header = await raf.read(64);
      if (header.isEmpty) return true;
      final str = utf8.decode(header, allowMalformed: true).trimLeft().toLowerCase();
      if (str.startsWith('<!doctype') ||
          str.startsWith('<html') ||
          str.startsWith('<?xml') ||
          str.startsWith('<head') ||
          str.startsWith('{"error"') ||
          str.startsWith('509 bandwidth') ||
          str.startsWith('error:')) {
        return true;
      }
    } finally {
      await raf.close();
    }
  } on Object {}
  return false;
}

