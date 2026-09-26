import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

enum ArtifactReadFailureKind {
  accessDenied,
  missing,
  staleLocator,
  shortRead,
  lengthChanged,
  ioFailure,
}

/// Typed failure emitted by one physical artifact access path.
///
/// [bytesEmitted] is relative to the current read request, while
/// [failedOffset] is the absolute artifact offset. Replica identity is optional
/// because low-level byte backends may fail before durable replica resolution;
/// persistent sealed-artifact reads enrich it with the selected replica id.
final class ArtifactReadFailure implements Exception {
  const ArtifactReadFailure({
    required this.kind,
    required this.accessLocator,
    required this.failedOffset,
    required this.bytesEmitted,
    this.replicaId,
    this.expectedLength,
    this.observedLength,
    this.cause,
  });

  final ArtifactReadFailureKind kind;
  final String accessLocator;
  final String? replicaId;
  final int failedOffset;
  final int bytesEmitted;
  final int? expectedLength;
  final int? observedLength;
  final Object? cause;

  ArtifactReadFailure withReplicaId(String value) => ArtifactReadFailure(
        kind: kind,
        accessLocator: accessLocator,
        replicaId: value,
        failedOffset: failedOffset,
        bytesEmitted: bytesEmitted,
        expectedLength: expectedLength,
        observedLength: observedLength,
        cause: cause,
      );

  @override
  String toString() => 'ArtifactReadFailure(${kind.name}, '
      'locator=$accessLocator, offset=$failedOffset, emitted=$bytesEmitted)';
}

/// Platform-neutral failure that a [SafTreeIo] adapter may throw before the
/// byte-access layer has enough locator/offset context to build
/// [ArtifactReadFailure].
final class SafTreeAccessFailure implements Exception {
  const SafTreeAccessFailure({
    required this.kind,
    required this.operation,
    this.cause,
  });

  final ArtifactReadFailureKind kind;
  final String operation;
  final Object? cause;

  @override
  String toString() => 'SafTreeAccessFailure(${kind.name}, $operation)';
}

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

/// One opened random-access view over a durable artifact locator.
///
/// This is intentionally separate from [ArtifactBytes.readChunks]: ordinary
/// callers keep stateless open/read/close semantics, while a proven immutable
/// READY generation may retain one descriptor and avoid paying provider path
/// resolution on every decoder range request. Callers must serialize reads.
abstract interface class ArtifactByteRangeReader {
  String get accessMode;
  String? get directFilePath;

  /// Exact physical length observed through this already-open generation.
  /// READY restore can use the same descriptor for seal-length preflight and
  /// subsequent decoder ranges instead of reopening the provider immediately.
  Future<int> length();

  Future<Uint8List> readRange(int start, int endExclusive);

  Future<void> close();
}

/// Opens a reusable reader when the concrete byte backend can safely retain a
/// descriptor. Unknown/custom [ArtifactBytes] implementations return null and
/// keep the historical stateless range path.
Future<ArtifactByteRangeReader?> openArtifactByteRangeReader(
  ArtifactBytes bytes,
  String path,
) async {
  if (bytes is CompositeArtifactBytes) {
    final target = bytes._target(path);
    if (target == null) return null;
    return openArtifactByteRangeReader(target, path);
  }
  if (bytes is LocalArtifactBytes) {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file) return null;
    final raf = await File(path).open();
    return _LocalArtifactByteRangeReader(path, raf);
  }
  if (bytes is SafArtifactBytes) {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || !bytes._belongsToThisTree(path)) return null;
    return _SafArtifactByteRangeReader(
      path: path,
      relativePath: parsed.relativePath,
      io: bytes._io,
    );
  }
  return null;
}

final class _LocalArtifactByteRangeReader implements ArtifactByteRangeReader {
  _LocalArtifactByteRangeReader(this._path, this._raf);

  final String _path;
  final RandomAccessFile _raf;
  bool _closed = false;

  @override
  String get accessMode => 'direct';

  @override
  String get directFilePath => _path;

  @override
  Future<int> length() async {
    if (_closed) {
      throw StateError('artifact range reader is closed');
    }
    try {
      return await _raf.length();
    } on FileSystemException catch (error) {
      throw ArtifactReadFailure(
        kind: _fileReadFailureKind(error),
        accessLocator: _path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    } on OSError catch (error) {
      throw ArtifactReadFailure(
        kind: _osReadFailureKind(error.errorCode),
        accessLocator: _path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  @override
  Future<Uint8List> readRange(int start, int endExclusive) async {
    if (_closed) {
      throw StateError('artifact range reader is closed');
    }
    if (start < 0 || endExclusive <= start) {
      throw RangeError.range(endExclusive, start + 1, null, 'endExclusive');
    }
    var position = start;
    final out = BytesBuilder(copy: false);
    try {
      await _raf.setPosition(start);
      while (position < endExclusive) {
        final chunk = await _raf.read(min(endExclusive - position, 512 * 1024));
        if (chunk.isEmpty) {
          throw ArtifactReadFailure(
            kind: ArtifactReadFailureKind.shortRead,
            accessLocator: _path,
            failedOffset: position,
            bytesEmitted: position - start,
            expectedLength: endExclusive - start,
            observedLength: position - start,
          );
        }
        out.add(chunk);
        position += chunk.length;
      }
      return out.takeBytes();
    } on ArtifactReadFailure {
      rethrow;
    } on FileSystemException catch (error) {
      throw ArtifactReadFailure(
        kind: _fileReadFailureKind(error),
        accessLocator: _path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error,
      );
    } on OSError catch (error) {
      throw ArtifactReadFailure(
        kind: _osReadFailureKind(error.errorCode),
        accessLocator: _path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }
}

final class _SafArtifactByteRangeReader implements ArtifactByteRangeReader {
  _SafArtifactByteRangeReader({
    required String path,
    required String relativePath,
    required SafTreeIo io,
  }) : _path = path,
       _relativePath = relativePath,
       _io = io;

  final String _path;
  final String _relativePath;
  final SafTreeIo _io;
  int? _handle;
  bool _closed = false;

  @override
  String get accessMode => 'saf';

  @override
  String? get directFilePath => null;

  Future<int> _ensureOpen() async {
    if (_closed) {
      throw StateError('artifact range reader is closed');
    }
    final existing = _handle;
    if (existing != null) return existing;
    final opened = await _io.open(_relativePath);
    if (opened == null) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.staleLocator,
        accessLocator: _path,
        failedOffset: 0,
        bytesEmitted: 0,
      );
    }
    _handle = opened;
    return opened;
  }

  @override
  Future<int> length() async {
    try {
      final handle = await _ensureOpen();
      return await _io.length(handle) ?? 0;
    } on ArtifactReadFailure {
      rethrow;
    } on SafTreeAccessFailure catch (error) {
      throw ArtifactReadFailure(
        kind: error.kind,
        accessLocator: _path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error.cause ?? error,
      );
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: _path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  @override
  Future<Uint8List> readRange(int start, int endExclusive) async {
    if (_closed) {
      throw StateError('artifact range reader is closed');
    }
    if (start < 0 || endExclusive <= start) {
      throw RangeError.range(endExclusive, start + 1, null, 'endExclusive');
    }
    var position = start;
    final out = BytesBuilder(copy: false);
    try {
      final handle = await _ensureOpen();
      if (_io is SafTreeRandomRead) {
        final randomRead = _io as SafTreeRandomRead;
        final expectedLength = endExclusive - start;
        final bytes = await randomRead.readAt(handle, start, expectedLength);
        if (bytes.length != expectedLength) {
          throw ArtifactReadFailure(
            kind: ArtifactReadFailureKind.shortRead,
            accessLocator: _path,
            failedOffset: start + bytes.length,
            bytesEmitted: bytes.length,
            expectedLength: expectedLength,
            observedLength: bytes.length,
          );
        }
        return bytes;
      }
      await _io.seek(handle, start);
      while (position < endExclusive) {
        final chunk = await _io.read(
          handle,
          min(endExclusive - position, 512 * 1024),
        );
        if (chunk.isEmpty) {
          throw ArtifactReadFailure(
            kind: ArtifactReadFailureKind.shortRead,
            accessLocator: _path,
            failedOffset: position,
            bytesEmitted: position - start,
            expectedLength: endExclusive - start,
            observedLength: position - start,
          );
        }
        out.add(chunk);
        position += chunk.length;
      }
      return out.takeBytes();
    } on ArtifactReadFailure {
      rethrow;
    } on SafTreeAccessFailure catch (error) {
      throw ArtifactReadFailure(
        kind: error.kind,
        accessLocator: _path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error.cause ?? error,
      );
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: _path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final handle = _handle;
    _handle = null;
    if (handle != null) await _io.close(handle);
  }
}

class LocalArtifactBytes implements ArtifactBytes {
  const LocalArtifactBytes();

  @override
  Future<bool> exists(String path) async {
    try {
      return await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file;
    } on FileSystemException catch (error) {
      throw ArtifactReadFailure(
        kind: _fileReadFailureKind(error),
        accessLocator: path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  @override
  Future<int> length(String path) async {
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return 0;
      }
      return await File(path).length();
    } on FileSystemException catch (error) {
      throw ArtifactReadFailure(
        kind: _fileReadFailureKind(error),
        accessLocator: path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    final file = File(path);
    var position = start;
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        if (type == FileSystemEntityType.notFound) {
          throw ArtifactReadFailure(
            kind: ArtifactReadFailureKind.missing,
            accessLocator: path,
            failedOffset: start,
            bytesEmitted: 0,
          );
        }
        // Symlinks and non-file entries remain unreadable by policy. Replica
        // ownership does not make an unsafe/non-file locator readable; keep
        // the historical empty-stream behavior rather than following it.
        return;
      }
      final raf = await file.open();
      try {
        final end = endExclusive ?? await file.length();
        await raf.setPosition(position);
        while (position < end) {
          final chunk = await raf.read(min(end - position, 512 * 1024));
          if (chunk.isEmpty) {
            throw ArtifactReadFailure(
              kind: ArtifactReadFailureKind.shortRead,
              accessLocator: path,
              failedOffset: position,
              bytesEmitted: position - start,
              expectedLength: end - start,
              observedLength: position - start,
            );
          }
          position += chunk.length;
          yield chunk;
        }
      } finally {
        await raf.close();
      }
    } on ArtifactReadFailure {
      rethrow;
    } on FileSystemException catch (error) {
      throw ArtifactReadFailure(
        kind: _fileReadFailureKind(error),
        accessLocator: path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error,
      );
    } on OSError catch (error) {
      throw ArtifactReadFailure(
        kind: _osReadFailureKind(error.errorCode),
        accessLocator: path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error,
      );
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
abstract interface class SafTreeRandomRead {
  /// Reads one exact range from an already-open descriptor as one physical
  /// provider operation. Implementations may satisfy it with pread/lseek+read,
  /// but callers rely on the range not being interleaved with unrelated SAF
  /// work between positioning and body reads.
  Future<Uint8List> readAt(int handle, int position, int length);
}

/// Optional process-local acceleration for provider-backed read paths.
///
/// Implementations may perform a bounded read-only provider warmup, but must
/// not create body authority, mutate namespace state, or retain a descriptor
/// whose lifetime escapes the warmup operation. `false` means unavailable or
/// unnecessary (for example a direct filesystem backend).
abstract interface class SafTreeReadPrewarmer {
  Future<bool> prewarmReadProvider();
}

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
    try {
      return await _io.exists(parsed.relativePath);
    } on SafTreeAccessFailure catch (error) {
      throw ArtifactReadFailure(
        kind: error.kind,
        accessLocator: path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error.cause ?? error,
      );
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  @override
  Future<int> length(String path) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || !_belongsToThisTree(path)) return 0;
    int? handle;
    try {
      handle = await _io.open(parsed.relativePath);
      if (handle == null) return 0;
      return await _io.length(handle) ?? 0;
    } on SafTreeAccessFailure catch (error) {
      throw ArtifactReadFailure(
        kind: error.kind,
        accessLocator: path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error.cause ?? error,
      );
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: path,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    } finally {
      if (handle != null) {
        try {
          await _io.close(handle);
        } on Object {
          // Probe cleanup cannot change the already observed length result.
        }
      }
    }
  }

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || !_belongsToThisTree(path)) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.staleLocator,
        accessLocator: path,
        failedOffset: start,
        bytesEmitted: 0,
      );
    }
    var position = start;
    int? handle;
    try {
      handle = await _io.open(parsed.relativePath);
      if (handle == null) {
        throw ArtifactReadFailure(
          kind: ArtifactReadFailureKind.staleLocator,
          accessLocator: path,
          failedOffset: start,
          bytesEmitted: 0,
        );
      }
      await _io.seek(handle, position);
      while (endExclusive == null || position < endExclusive) {
        final remaining =
            endExclusive == null ? 512 * 1024 : endExclusive - position;
        final chunk = await _io.read(handle, remaining.clamp(0, 512 * 1024));
        if (chunk.isEmpty) {
          if (endExclusive != null && position < endExclusive) {
            throw ArtifactReadFailure(
              kind: ArtifactReadFailureKind.shortRead,
              accessLocator: path,
              failedOffset: position,
              bytesEmitted: position - start,
              expectedLength: endExclusive - start,
              observedLength: position - start,
            );
          }
          break;
        }
        position += chunk.length;
        yield chunk;
      }
    } on ArtifactReadFailure {
      rethrow;
    } on SafTreeAccessFailure catch (error) {
      throw ArtifactReadFailure(
        kind: error.kind,
        accessLocator: path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error.cause ?? error,
      );
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: path,
        failedOffset: position,
        bytesEmitted: position - start,
        cause: error,
      );
    } finally {
      if (handle != null) {
        try {
          await _io.close(handle);
        } on Object {
          // Closing a consumed descriptor is cleanup, not evidence that bytes
          // already emitted became invalid. The next access will classify a
          // real open/read failure if the locator is no longer usable.
        }
      }
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
    if (target == null) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.staleLocator,
        accessLocator: path,
        failedOffset: start,
        bytesEmitted: 0,
      );
    }
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
ArtifactReadFailureKind _fileReadFailureKind(FileSystemException error) =>
    _osReadFailureKind(error.osError?.errorCode);

ArtifactReadFailureKind _osReadFailureKind(int? errorCode) {
  return switch (errorCode) {
    1 || 5 || 13 => ArtifactReadFailureKind.accessDenied,
    2 || 3 => ArtifactReadFailureKind.missing,
    116 => ArtifactReadFailureKind.staleLocator,
    _ => ArtifactReadFailureKind.ioFailure,
  };
}

typedef SafTemporaryLifecycleHook = Future<void> Function(
  String temporaryPath,
);

Future<void> copyFileIntoSaf(
  SafTreeIo io,
  File sourceFile,
  String relativePath, {
  SafTemporaryLifecycleHook? beforeTemporaryCreate,
  SafTemporaryLifecycleHook? afterTemporaryAbsent,
}) async {
  await _writeSafAtomically(
    io,
    relativePath,
    (temporaryPath) async {
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
    },
    beforeTemporaryCreate: beforeTemporaryCreate,
    afterTemporaryAbsent: afterTemporaryAbsent,
  );
}

/// Writes [bytes] into a committed SAF file without exposing a partially
/// written final path to readers.
Future<void> writeBytesToSaf(
  SafTreeIo io,
  String relativePath,
  Uint8List bytes, {
  SafTemporaryLifecycleHook? beforeTemporaryCreate,
  SafTemporaryLifecycleHook? afterTemporaryAbsent,
}) async {
  await _writeSafAtomically(
    io,
    relativePath,
    (temporaryPath) async {
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
    },
    beforeTemporaryCreate: beforeTemporaryCreate,
    afterTemporaryAbsent: afterTemporaryAbsent,
  );
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
  Future<void> Function(String temporaryPath) write, {
  SafTemporaryLifecycleHook? beforeTemporaryCreate,
  SafTemporaryLifecycleHook? afterTemporaryAbsent,
}) async {
  if (!_isSafeSafRelativePath(relativePath)) {
    throw ArgumentError.value(relativePath, 'relativePath', 'must be safe');
  }
  final temporaryPath =
      '$relativePath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}';
  await beforeTemporaryCreate?.call(temporaryPath);
  try {
    await write(temporaryPath);
    await commitSafTemporary(io, temporaryPath, relativePath);
  } finally {
    if (await io.exists(temporaryPath)) {
      await io.delete(temporaryPath);
    }
    if (!await io.exists(temporaryPath)) {
      await afterTemporaryAbsent?.call(temporaryPath);
    }
  }
}

/// Sniffs the image format extension supported by ZIC's image presentation
/// stack from bounded header bytes. Falls back to `bin` when no supported
/// signature is present; callers must not infer image validity from a filename.
String sniffImageExtensionFromBytes(List<int> header) {
  bool at(int offset, List<int> signature) {
    if (offset < 0 || header.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (header[offset + index] != signature[index]) return false;
    }
    return true;
  }

  String fourCc(int offset) =>
      String.fromCharCodes(header.sublist(offset, offset + 4)).toLowerCase();

  if (at(0, const <int>[0xff, 0xd8, 0xff])) return 'jpg';
  if (at(0, const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'png';
  }
  if (header.length >= 12 &&
      at(0, const <int>[0x52, 0x49, 0x46, 0x46]) &&
      at(8, const <int>[0x57, 0x45, 0x42, 0x50])) {
    return 'webp';
  }
  if (at(0, const <int>[0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      at(0, const <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
    return 'gif';
  }
  if (at(0, const <int>[0x42, 0x4d])) return 'bmp';
  if (at(0, const <int>[0x49, 0x49, 0x2a, 0x00]) ||
      at(0, const <int>[0x4d, 0x4d, 0x00, 0x2a])) {
    return 'tiff';
  }
  if (at(0, const <int>[0x00, 0x00, 0x01, 0x00])) return 'ico';

  if (header.length >= 12 && at(4, const <int>[0x66, 0x74, 0x79, 0x70])) {
    final brands = <String>{};
    for (var offset = 8; offset + 4 <= header.length; offset += 4) {
      brands.add(fourCc(offset));
    }
    if (brands.any(const <String>{'avif', 'avis'}.contains)) return 'avif';
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
      return 'heif';
    }
  }
  return 'bin';
}

/// Reads intrinsic dimensions from bounded encoded-image header bytes without
/// decoding pixels. Returns null when the format needs metadata beyond the
/// supplied prefix (for example a JPEG whose SOF follows a large EXIF block).
({int width, int height})? sniffImageDimensionsFromBytes(List<int> header) {
  bool at(int offset, List<int> signature) {
    if (offset < 0 || header.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (header[offset + index] != signature[index]) return false;
    }
    return true;
  }

  int u16be(int offset) => (header[offset] << 8) | header[offset + 1];
  int u16le(int offset) => header[offset] | (header[offset + 1] << 8);
  int u32be(int offset) =>
      (header[offset] << 24) |
      (header[offset + 1] << 16) |
      (header[offset + 2] << 8) |
      header[offset + 3];
  int u32le(int offset) =>
      header[offset] |
      (header[offset + 1] << 8) |
      (header[offset + 2] << 16) |
      (header[offset + 3] << 24);

  ({int width, int height})? dimensions(int width, int height) =>
      width > 0 && height > 0 ? (width: width, height: height) : null;

  if (header.length >= 24 &&
      at(0, const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) &&
      at(12, const <int>[0x49, 0x48, 0x44, 0x52])) {
    return dimensions(u32be(16), u32be(20));
  }
  if (header.length >= 10 &&
      (at(0, const <int>[0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
          at(0, const <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]))) {
    return dimensions(u16le(6), u16le(8));
  }
  if (header.length >= 26 && at(0, const <int>[0x42, 0x4d])) {
    final width = u32le(18);
    final rawHeight = u32le(22);
    final height = rawHeight & 0x80000000 == 0
        ? rawHeight
        : ((~rawHeight + 1) & 0xffffffff);
    return dimensions(width, height);
  }
  if (header.length >= 8 && at(0, const <int>[0x00, 0x00, 0x01, 0x00])) {
    return dimensions(
      header[6] == 0 ? 256 : header[6],
      header[7] == 0 ? 256 : header[7],
    );
  }
  if (header.length >= 4 && at(0, const <int>[0xff, 0xd8, 0xff])) {
    var offset = 2;
    while (offset + 3 < header.length) {
      if (header[offset] != 0xff) {
        offset++;
        continue;
      }
      while (offset < header.length && header[offset] == 0xff) {
        offset++;
      }
      if (offset >= header.length) break;
      final marker = header[offset++];
      if (marker == 0xd8 ||
          marker == 0xd9 ||
          marker == 0x01 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (marker == 0xda || offset + 1 >= header.length) break;
      final segmentLength = u16be(offset);
      if (segmentLength < 2 || offset + segmentLength > header.length) break;
      final isStartOfFrame = marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc;
      if (isStartOfFrame && segmentLength >= 7) {
        return dimensions(u16be(offset + 5), u16be(offset + 3));
      }
      offset += segmentLength;
    }
  }
  return null;
}

/// Sniffs a supported image extension from the first 32 bytes of [file].
/// Falls back to `bin` on read failure or unknown/unsupported format.
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

