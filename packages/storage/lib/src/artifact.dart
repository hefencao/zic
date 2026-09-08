import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'crc32.dart';

enum ArtifactState { empty, partial, sealed, promoted, disposed }

final class ArtifactSnapshot {
  const ArtifactSnapshot({
    required this.state,
    required this.committedLength,
    required this.checksum,
    required this.partialPath,
    required this.finalPath,
    required this.metaPath,
    required this.finalMetaPath,
  });

  final ArtifactState state;
  final int committedLength;
  final String checksum;
  final String partialPath;
  final String finalPath;
  final String metaPath;
  final String finalMetaPath;
}

final class Artifact {
  Artifact({
    required this.partialPath,
    required this.finalPath,
    String? metaPath,
    String? finalMetaPath,
  })  : metaPath = metaPath ?? '$partialPath.meta',
        finalMetaPath = finalMetaPath ?? '$finalPath.meta';

  final String partialPath;
  final String finalPath;
  final String metaPath;
  final String finalMetaPath;

  ArtifactState _state = ArtifactState.empty;
  IOSink? _sink;
  Crc32 _crc = Crc32();
  bool _checksumDirty = false;
  int _committed = 0;

  // Every file-mutating operation is serialized through one tail. In
  // particular, reset/dispose cannot delete a file while an append or metadata
  // rename that was started earlier is still in flight, and operations started
  // after the boundary are ordered after the new artifact state.
  Future<void> _mutationTail = Future<void>.value();

  ArtifactState get state => _state;
  int get committedLength => _committed;
  /// A checksum is authoritative only after the current file contents have
  /// been hashed. Partial hot-path appends deliberately defer CRC work so
  /// network ingress does not run a byte-by-byte Dart loop on the UI isolate.
  String get checksum => _checksumDirty ? '' : _crc.hex;
  bool get hasOpenWriter => _sink != null;

  ArtifactSnapshot get snapshot => ArtifactSnapshot(
        state: _state,
        committedLength: _committed,
        checksum: checksum,
        partialPath: partialPath,
        finalPath: finalPath,
        metaPath: metaPath,
        finalMetaPath: finalMetaPath,
      );

  Future<ArtifactSnapshot> restore({
    bool verifyPromotedChecksum = true,
  }) => _enqueueMutation(
        () => _restore(
          verifyPromotedChecksum: verifyPromotedChecksum,
        ),
      );

  /// Returns whether this deterministic session artifact has a physical body
  /// that must retain restore priority over an external durable authority.
  ///
  /// This is a read-only admission probe, not restore evidence. It preserves
  /// the same path/immediate-parent symlink rejection as [restore], but does
  /// not create directories, read sidecars, hash bytes, or mutate artifact
  /// state. Any non-file/non-missing body node is treated as restorable so the
  /// full restore path remains authoritative for unusual filesystem states.
  Future<bool> hasRestorableBody() async {
    await _mutationTail;
    _requireNotDisposed();
    final checkedParents = <String>{};
    for (final path in <String>[partialPath, finalPath]) {
      final type = await _artifactPathType(
        path,
        checkedParents: checkedParents,
      );
      if (type != FileSystemEntityType.notFound) return true;
    }
    return false;
  }

  /// Opens an already-indexed mutable partial without hashing its whole body.
  ///
  /// This is deliberately narrower than [restore]: the caller must already own
  /// a durable partial binding and provide its exact indexed length. The body
  /// remains unsealed and its checksum stays dirty, so [seal] performs the
  /// authoritative whole-file CRC before promotion. This lets a transfer adopt
  /// a large durable spool without an O(prefix) read before network resume.
  Future<ArtifactSnapshot> adoptExistingPartial({
    required int expectedLength,
  }) => _enqueueMutation(
        () => _adoptExistingPartial(expectedLength: expectedLength),
      );

  Future<ArtifactSnapshot> _adoptExistingPartial({
    required int expectedLength,
  }) async {
    _requireNotDisposed();
    if (_state != ArtifactState.empty) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'existing partial adoption requires an empty artifact handle',
      );
    }
    if (expectedLength <= 0) {
      throw ArgumentError.value(
        expectedLength,
        'expectedLength',
        'must be positive',
      );
    }
    await _closeWriter();
    await _rejectArtifactLinks();
    final partial = File(partialPath);
    if (!await partial.exists()) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'indexed partial disappeared before adoption',
      );
    }
    final actualLength = await partial.length();
    if (actualLength != expectedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'indexed partial length changed before adoption: '
            '$actualLength/$expectedLength',
      );
    }
    _crc = Crc32();
    _checksumDirty = true;
    _committed = actualLength;
    _state = ArtifactState.partial;
    return snapshot;
  }

  Future<ArtifactSnapshot> _restore({
    required bool verifyPromotedChecksum,
  }) async {
    _requireNotDisposed();
    try {
      await _closeWriter();
      await _rejectArtifactLinks();

      final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      // A ready sidecar is only a checksum claim, not proof that the data file
      // still has the claimed bytes. Even callers that request the historical
      // fast path must verify a same-length file before treating it as ready;
      // otherwise a silent in-place overwrite is promoted as a new artifact.
      final restoredFromMeta = await _restorePromotedFromMeta(finalFile,
        verifyChecksum: verifyPromotedChecksum,
      );
      if (!restoredFromMeta) {
        await _rehash(finalFile);
        if (_committed <= 0) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'promoted artifact is empty',
          );
        }
        // A valid body with a stale or malformed sidecar is still a promoted
        // artifact, but leaving the sidecar unrepaired would make the next
        // recovery depend on another full rehash and could leave the ready
        // proof invalid indefinitely. The body has just been verified above,
        // so refresh the sidecar for both the normal and historical fast-path
        // callers.
        await _repairFinalMetaAfterVerification();
      }
      if (_committed <= 0) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'promoted artifact is empty',
        );
      }
      _state = ArtifactState.promoted;
      await _recoverFinalMeta();
      // A crash after an idempotent same-content promotion can leave both
      // the final body and the old partial body/sidecars. Once the final body
      // has been verified, the partial generation is stale and must not remain
      // as an orphan that a later resume could mistake for writable state.
      for (final path in <String>[partialPath, metaPath, '$metaPath.tmp']) {
        final stale = File(path);
        if (await stale.exists()) await stale.delete();
      }
      return snapshot;
    }

    final partial = File(partialPath);
    if (await partial.exists()) {
      await _rehash(partial);
      _state = ArtifactState.partial;
      return snapshot;
    }

    await partial.parent.create(recursive: true);
    _crc = Crc32();
    _checksumDirty = false;
    _committed = 0;
      _state = ArtifactState.partial;
      return snapshot;
    } catch (_) {
      // A failed restore must not leave the in-memory artifact claiming the
      // bytes that caused the failure. Keep the physical files untouched for
      // recovery/diagnostics, but make a subsequent owner decision start from
      // an explicit empty state with no stale writer/checksum evidence.
      _sink = null;
      _crc = Crc32();
      _checksumDirty = false;
      _committed = 0;
      _state = ArtifactState.empty;
      rethrow;
    }
  }

  Future<void> append(int offset, List<int> bytes) =>
      appendOwned(offset, Uint8List.fromList(bytes));

  /// Appends a chunk whose byte storage is exclusively owned by the caller.
  ///
  /// DownloadSession uses this path to share one immutable chunk between the
  /// buffered artifact writer and native ingress without a second Dart copy.
  Future<void> appendOwned(int offset, Uint8List bytes) =>
      _enqueueMutation(() => _append(offset, bytes));

  Future<void> _append(int offset, List<int> bytes) async {
    _requireState(ArtifactState.partial);
    if (offset != _committed) {
      throw Failure(
        code: ErrorCode.invalidOffset,
        message: 'expected offset $_committed, got $offset',
      );
    }
    if (bytes.isEmpty) {
      return;
    }
    final writer = await _writer();
    try {
      writer.add(bytes);
    } on Object catch (error, stackTrace) {
      // A sink can fail after accepting part of a chunk. Retire it before the
      // error escapes so callers cannot leave the Artifact permanently
      // writer-busy; restore/re-hash remains the authority for any bytes that
      // made it to disk before the write failed.
      try {
        await _closeWriter();
        await _rehash(File(partialPath));
      } on Object {
        // Preserve the original write failure. A later restore can recover
        // the physical prefix if closing or re-hashing also fails.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    _committed += bytes.length;
    _checksumDirty = true;
  }

  Future<void> flush() => _enqueueMutation(() async {
        _requireNotDisposed();
        await _sink?.flush();
      });

  Future<void> pause() => _enqueueMutation(_pause);

  Future<void> _pause() async {
    _requireState(ArtifactState.partial);
    // _closeWriter flushes before closing and, unlike a separate flush call,
    // still closes the sink when that flush fails.
    await _closeWriter();
    await _refreshMeta(state: 'partial');
  }

  Future<ArtifactSnapshot> seal({
    int? expectedLength,
    String? expectedChecksum,
  }) => _enqueueMutation(
        () => _seal(
          expectedLength: expectedLength,
          expectedChecksum: expectedChecksum,
        ),
      );

  Future<ArtifactSnapshot> _seal({
    required int? expectedLength,
    required String? expectedChecksum,
  }) async {
    _requireState(ArtifactState.partial);
    // _closeWriter owns the flush/close pair so a failed flush cannot leave
    // the append sink open across a failed seal.
    await _closeWriter();

    if (_checksumDirty) {
      await _rehash(File(partialPath));
    }

    if (_committed <= 0) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'cannot seal an empty artifact',
      );
    }
    if (expectedLength != null && expectedLength != _committed) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'expected $expectedLength bytes, got $_committed',
      );
    }
    if (expectedChecksum != null &&
        expectedChecksum.toLowerCase() != checksum) {
      throw Failure(
        code: ErrorCode.checksumMismatch,
        message: 'expected checksum $expectedChecksum, got $checksum',
      );
    }
    await _refreshMeta(state: 'sealed');
    _state = ArtifactState.sealed;
    return snapshot;
  }

  Future<ArtifactSnapshot> promote() => _enqueueMutation(_promote);

  Future<ArtifactSnapshot> _promote() async {
    _requireState(ArtifactState.sealed);
    await _rejectArtifactLinks();
    if (_committed <= 0) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'cannot promote an empty artifact',
      );
    }
    final partial = File(partialPath);
    final target = File(finalPath);
    await target.parent.create(recursive: true);

    final sourceMeta = await _readJson(File(metaPath)) ?? <String, Object?>{};
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final finalMeta = <String, Object?>{
      ...sourceMeta,
      'artifactState': 'ready',
      'path': finalPath,
      'bytes': _committed,
      'checksum': checksum,
      'touchedUs': now,
      'createdUs': sourceMeta['createdUs'] is int
          ? sourceMeta['createdUs']
          : now,
    };
    final stagedMeta = File('$finalMetaPath.tmp');
    await _writeJson(stagedMeta, finalMeta);

    if (await target.exists()) {
      final existingCrc = Crc32();
      var existingLength = 0;
      await for (final chunk in target.openRead()) {
        existingCrc.add(chunk);
        existingLength += chunk.length;
      }
      if (existingLength != _committed || existingCrc.hex != checksum) {
        await stagedMeta.delete();
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'final artifact already exists with different content',
        );
      }
      if (await partial.exists()) {
        await partial.delete();
      }
    } else {
      await partial.rename(finalPath);
    }

    await _replaceFile(stagedMeta, File(finalMetaPath));
    for (final path in <String>[metaPath, '$metaPath.tmp']) {
      final metadata = File(path);
      if (await metadata.exists()) {
        await metadata.delete();
      }
    }
    _state = ArtifactState.promoted;
    return snapshot;
  }

  Future<Uint8List> readBytes() async {
    _requireNotDisposed();
    await flush();
    final reader = await _openReadableDataFile();
    if (reader == null) return Uint8List(0);
    try {
      final length = await reader.length();
      if (length == 0) return Uint8List(0);
      await reader.setPosition(0);
      return await reader.read(length);
    } finally {
      await reader.close();
    }
  }

  Stream<List<int>> readChunks({
    int chunkSize = 256 * 1024,
    int start = 0,
    int? endExclusive,
  }) async* {
    _requireNotDisposed();
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    if (start < 0 || (endExclusive != null && endExclusive < start)) {
      throw RangeError('invalid artifact range $start..$endExclusive');
    }
    await flush();
    final reader = await _openReadableDataFile();
    if (reader == null) return;
    try {
      final length = await reader.length();
      if (start >= length) return;
      final limit = (endExclusive ?? length).clamp(start, length).toInt();
      await reader.setPosition(start);
      var offset = start;
      while (offset < limit) {
        final readSize = (limit - offset).clamp(1, chunkSize).toInt();
        final chunk = await reader.read(readSize);
        if (chunk.isEmpty) break;
        offset += chunk.length;
        yield chunk;
      }
    } finally {
      await reader.close();
    }
  }

  Future<List<int>> readPrefix([int maxBytes = 12]) async {
    // Unlike metadata reads, a prefix can race an open IOSink. Queue a real
    // flush so callers cannot observe a shorter durable file merely because
    // the preceding append completed after writer.add() but before the sink
    // delivered its buffered bytes to the filesystem.
    await flush();
    _requireNotDisposed();
    if (maxBytes <= 0) return const <int>[];
    final reader = await _openReadableDataFile();
    if (reader == null) return const <int>[];
    try {
      final length = await reader.length();
      if (length == 0) return const <int>[];
      await reader.setPosition(0);
      return await reader.read(length < maxBytes ? length : maxBytes);
    } finally {
      await reader.close();
    }
  }

  /// Opens the authoritative encoded file while this Artifact owns a
  /// partial-to-final promotion.
  ///
  /// The filesystem rename and the in-memory [ArtifactState] transition are
  /// not one atomic operation. Opening the preferred path and then falling
  /// back to the alternate path keeps that owner-internal transition from
  /// leaking as an artificial zero-byte source. Returning an open file handle
  /// also removes the exists()-then-open TOCTOU window: once opened, a rename
  /// does not invalidate the Reader's handle.
  Future<RandomAccessFile?> _openReadableDataFile() async {
    _requireNotDisposed();
    final preferred =
        _state == ArtifactState.promoted ? finalPath : partialPath;
    final alternate =
        _state == ArtifactState.promoted ? partialPath : finalPath;
    for (final path in <String>[preferred, alternate]) {
      await _rejectLink(path);
      try {
        return await File(path).open(mode: FileMode.read);
      } on FileSystemException {
        // Promotion may have renamed the file between state observation and
        // open. The alternate path belongs to the same Artifact owner and is
        // therefore the only legal fallback.
      }
    }
    return null;
  }

  Future<Map<String, Object?>?> readMeta() async {
    await _mutationTail;
    _requireNotDisposed();
    if (_state == ArtifactState.promoted) {
      final ready = await _readJson(File(finalMetaPath));
      if (ready != null) {
        return ready;
      }
      final staged = await _readJson(File('$finalMetaPath.tmp'));
      if (staged != null) {
        return staged;
      }
    }
    return _readJson(File(metaPath));
  }

  Future<void> writeMeta(Map<String, Object?> value) =>
      _enqueueMutation(() => _writeMeta(value));

  Future<void> _writeMeta(Map<String, Object?> value) async {
    _requireNotDisposed();
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _writeJson(
      File(metaPath),
      <String, Object?>{
        ...value,
        'artifactState': 'partial',
        'path': partialPath,
        'createdUs': value['createdUs'] is int ? value['createdUs'] : now,
        'touchedUs': now,
      },
    );
  }

  Future<void> reset({bool deleteFinal = false}) =>
      _enqueueMutation(() => _reset(deleteFinal: deleteFinal));

  Future<void> _reset({required bool deleteFinal}) async {
    _requireNotDisposed();
    await _closeWriter();
    for (final path in <String>[
      partialPath,
      metaPath,
      '$metaPath.tmp',
      if (deleteFinal) finalPath,
      if (deleteFinal) finalMetaPath,
      if (deleteFinal) '$finalMetaPath.tmp',
    ]) {
      await _rejectLink(path);
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _crc = Crc32();
    _checksumDirty = false;
    _committed = 0;
    _state = ArtifactState.empty;
  }

  Future<void> deleteAll() => reset(deleteFinal: true);

  Future<void> dispose() => _enqueueMutation(_dispose);

  Future<void> _dispose() async {
    if (_state == ArtifactState.disposed) {
      return;
    }
    await _closeWriter();
    _state = ArtifactState.disposed;
  }

  Future<void> _refreshMeta({required String state}) async {
    final existing = await _readJson(File(metaPath));
    if (existing == null) {
      return;
    }
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _writeJson(
      File(metaPath),
      <String, Object?>{
        ...existing,
        'artifactState': state,
        'path': partialPath,
        'bytes': _committed,
        if (checksum.isNotEmpty) 'checksum': checksum,
        'touchedUs': now,
        'createdUs': existing['createdUs'] is int ? existing['createdUs'] : now,
      },
    );
  }

  Future<void> _recoverFinalMeta() async {
    final finalMeta = File(finalMetaPath);
    if (await finalMeta.exists()) {
      return;
    }
    final staged = File('$finalMetaPath.tmp');
    if (await staged.exists()) {
      await _replaceFile(staged, finalMeta);
      return;
    }
    final partialMeta = File(metaPath);
    if (await partialMeta.exists()) {
      final raw = await _readJson(partialMeta) ?? <String, Object?>{};
      final now = DateTime.now().toUtc().microsecondsSinceEpoch;
      await _writeJson(finalMeta, <String, Object?>{
        ...raw,
        'artifactState': 'ready',
        'path': finalPath,
        'bytes': _committed,
        'checksum': checksum,
        'touchedUs': now,
        'createdUs': raw['createdUs'] is int ? raw['createdUs'] : now,
      });
      await partialMeta.delete();
    }
  }

  Future<Map<String, Object?>?> _readJson(File file) async {
    await _rejectLink(file.path);
    if (!await file.exists()) {
      return null;
    }
    final Object? value;
    try {
      value = jsonDecode(await file.readAsString());
    } on FormatException catch (error) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact metadata is invalid JSON',
        cause: error,
      );
    }
    if (value is! Map) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact metadata is not an object',
      );
    }
    return Map<String, Object?>.from(value);
  }

  Future<void> _writeJson(File target, Map<String, Object?> value) async {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    await _rejectLink(target.path);
    await _rejectLink(temp.path);
    await temp.writeAsString(jsonEncode(value), flush: true);
    await _replaceFile(temp, target);
  }

  Future<void> _replaceFile(File source, File target) async {
    await _rejectLink(source.path);
    await _rejectLink(target.path);
    try {
      await source.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) {
        await target.delete();
      }
      await source.rename(target.path);
    }
  }

  Future<bool> _restorePromotedFromMeta(
    File file, {
    bool verifyChecksum = true,
  }) async {
    final Map<String, Object?>? metadata;
    try {
      metadata = await _readJson(File(finalMetaPath)) ??
          await _readJson(File('$finalMetaPath.tmp'));
    } on Failure catch (error) {
      if (error.code != ErrorCode.artifactCorruption) rethrow;
      return false;
    }
    final bytes = metadata?['bytes'];
    final checksum = metadata?['checksum'];
    if (metadata?['artifactState'] != 'ready' ||
        bytes is! int ||
        bytes < 0 ||
        checksum is! String ||
        !RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(checksum)) {
      return false;
    }
    if (await file.length() != bytes) return false;
    if (verifyChecksum) {
      await _rehash(file);
      if (checksum.toLowerCase() != this.checksum) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'promoted artifact checksum does not match its metadata',
        );
      }
      return true;
    }
    _crc = Crc32.fromHex(checksum);
    _checksumDirty = false;
    _committed = bytes;
    return true;
  }

  Future<void> _repairFinalMetaAfterVerification() async {
    Map<String, Object?> raw = <String, Object?>{};
    for (final file in <File>[
      File(finalMetaPath),
      File('$finalMetaPath.tmp'),
      File(metaPath),
    ]) {
      try {
        final value = await _readJson(file);
        if (value != null) {
          raw = value;
          break;
        }
      } on Failure catch (error) {
        if (error.code != ErrorCode.artifactCorruption) rethrow;
      }
    }
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _writeJson(File(finalMetaPath), <String, Object?>{
      ...raw,
      'artifactState': 'ready',
      'path': finalPath,
      'bytes': _committed,
      'checksum': checksum,
      'touchedUs': now,
      'createdUs': raw['createdUs'] is int ? raw['createdUs'] : now,
    });
    for (final path in <String>[
      '$finalMetaPath.tmp',
      metaPath,
      '$metaPath.tmp',
    ]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _rehash(File file) async {
    final path = file.path;
    final result = await Isolate.run<(int, String)>(() {
      final crc = Crc32();
      var length = 0;
      final reader = File(path).openSync();
      final buffer = Uint8List(256 * 1024);
      try {
        while (true) {
          final count = reader.readIntoSync(buffer);
          if (count <= 0) break;
          crc.add(count == buffer.length
              ? buffer
              : Uint8List.sublistView(buffer, 0, count));
          length += count;
        }
      } finally {
        reader.closeSync();
      }
      return (length, crc.hex);
    });
    _crc = Crc32.fromHex(result.$2);
    _checksumDirty = false;
    _committed = result.$1;
  }

  Future<IOSink> _writer() async {
    final existing = _sink;
    if (existing != null) {
      return existing;
    }
    await _rejectLink(partialPath);
    final partial = File(partialPath);
    await partial.parent.create(recursive: true);
    final length = await partial.exists() ? await partial.length() : 0;
    if (length != _committed) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'partial length changed from $_committed to $length',
      );
    }
    final writer = partial.openWrite(mode: FileMode.append);
    _sink = writer;
    return writer;
  }

  Future<T> _enqueueMutation<T>(Future<T> Function() operation) {
    final previous = _mutationTail;
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    _mutationTail = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return current;
  }

  Future<void> _rejectArtifactLinks() async {
    final checkedParents = <String>{};
    for (final path in <String>[
      partialPath,
      finalPath,
      metaPath,
      finalMetaPath,
      '$metaPath.tmp',
      '$finalMetaPath.tmp',
    ]) {
      await _rejectLink(path, checkedParents: checkedParents);
    }
  }

  Future<void> _rejectLink(String path, {Set<String>? checkedParents}) async {
    await _artifactPathType(path, checkedParents: checkedParents);
  }

  Future<FileSystemEntityType> _artifactPathType(
    String path, {
    Set<String>? checkedParents,
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact path must not contain a symlink: $path',
      );
    }
    final parent = File(path).parent.path;
    if (checkedParents == null || checkedParents.add(parent)) {
      final parentType = await FileSystemEntity.type(parent, followLinks: false);
      if (parentType == FileSystemEntityType.link) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'artifact path must not contain a symlink: $path',
        );
      }
    }
    return type;
  }

  Future<void> _closeWriter() async {
    Object? firstError;
    StackTrace? firstStack;
    final writer = _sink;
    _sink = null;
    if (writer != null) {
      try {
        await writer.flush();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
      try {
        await writer.close();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack!);
    }
  }

  void _requireState(ArtifactState expected) {
    _requireNotDisposed();
    if (_state != expected) {
      throw Failure(
        code: ErrorCode.invalidState,
        message: 'expected artifact state ${expected.name}, got ${_state.name}',
      );
    }
  }

  void _requireNotDisposed() {
    if (_state == ArtifactState.disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'artifact is disposed',
      );
    }
  }
}
