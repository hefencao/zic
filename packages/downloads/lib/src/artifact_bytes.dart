import 'dart:async';
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
  Future<bool> exists(String path) async => File(path).exists();

  @override
  Future<int> length(String path) => File(path).length();

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    final file = File(path);
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
    if (await file.exists()) {
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

  Future<bool> exists(String relativePath);

  Future<List<SafTreeFile>> list(String relativePath);
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
  return (treeUri: treeUri, relativePath: relativePath);
}

String encodeSafRecordPath({
  required String treeUri,
  required String relativePath,
}) =>
    'saf:${Uri.encodeComponent(treeUri)}?path=${Uri.encodeComponent(relativePath)}';

class SafArtifactBytes implements ArtifactBytes {
  SafArtifactBytes(this._io);

  final SafTreeIo _io;

  @override
  Future<bool> exists(String path) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null) return false;
    return _io.exists(parsed.relativePath);
  }

  @override
  Future<int> length(String path) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null) return 0;
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
    if (parsed == null) return;
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
    if (parsed == null) return;
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

  ArtifactBytes _target(String path) {
    if (path.startsWith('saf:')) {
      final safBytes = saf;
      if (safBytes != null) return safBytes;
    }
    return local;
  }

  @override
  Future<bool> exists(String path) => _target(path).exists(path);

  @override
  Future<int> length(String path) => _target(path).length(path);

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) =>
      _target(path).readChunks(
        path,
        start: start,
        endExclusive: endExclusive,
      );

  @override
  Future<void> delete(String path) => _target(path).delete(path);
}

/// Copies [sourceFile] into the SAF tree at [relativePath], truncating any
/// previous content. Used to mirror freshly promoted finals out of the local
/// staging area.
Future<void> copyFileIntoSaf(
  SafTreeIo io,
  File sourceFile,
  String relativePath,
) async {
  final handle = await io.open(relativePath, mode: SafWriteMode.writeTruncate);
  if (handle == null) {
    throw StateError('SAF tree refused create for $relativePath');
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
}

/// Writes [bytes] directly into the SAF tree at [relativePath].
Future<void> writeBytesToSaf(
  SafTreeIo io,
  String relativePath,
  Uint8List bytes,
) async {
  final handle = await io.open(relativePath, mode: SafWriteMode.writeTruncate);
  if (handle == null) {
    throw StateError('SAF tree refused create for $relativePath');
  }
  try {
    await io.write(handle, bytes);
  } finally {
    await io.close(handle);
  }
}

/// Sniffs the image format extension (webp, jpg, png, gif, avif) from the first
/// 32 bytes of [file]. Falls back to 'bin' on failure or unknown format.
Future<String> sniffImageExtension(File file) async {
  try {
    final raf = await file.open(mode: FileMode.read);
    try {
      final header = await raf.read(32);
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
    } finally {
      await raf.close();
    }
  } on Object {
    // Fall back to bin on read errors.
  }
  return 'bin';
}

