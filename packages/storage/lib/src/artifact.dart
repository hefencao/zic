import 'dart:convert';
import 'dart:io';

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
  RandomAccessFile? _file;
  Crc32 _crc = Crc32();
  int _committed = 0;
  Future<void> _writeTail = Future<void>.value();

  ArtifactState get state => _state;
  int get committedLength => _committed;
  String get checksum => _crc.hex;
  bool get hasOpenWriter => _file != null;

  ArtifactSnapshot get snapshot => ArtifactSnapshot(
        state: _state,
        committedLength: _committed,
        checksum: checksum,
        partialPath: partialPath,
        finalPath: finalPath,
        metaPath: metaPath,
        finalMetaPath: finalMetaPath,
      );

  Future<ArtifactSnapshot> restore() async {
    _requireNotDisposed();
    await _closeWriter();

    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await _rehash(finalFile);
      _state = ArtifactState.promoted;
      await _recoverFinalMeta();
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
    _committed = 0;
    _state = ArtifactState.partial;
    return snapshot;
  }

  Future<void> append(int offset, List<int> bytes) {
    final chunk = List<int>.of(bytes, growable: false);
    final operation = _writeTail.then<void>((_) => _append(offset, chunk));
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

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
    await writer.writeFrom(bytes);
    _crc.add(bytes);
    _committed += bytes.length;
  }

  Future<void> flush() async {
    _requireNotDisposed();
    await _writeTail;
    await _file?.flush();
  }

  Future<void> pause() async {
    _requireState(ArtifactState.partial);
    await flush();
    await _closeWriter();
    await _refreshMeta(state: 'partial');
  }

  Future<ArtifactSnapshot> seal({
    int? expectedLength,
    String? expectedChecksum,
  }) async {
    _requireState(ArtifactState.partial);
    await flush();
    await _closeWriter();

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

  Future<ArtifactSnapshot> promote() async {
    _requireState(ArtifactState.sealed);
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

  Stream<List<int>> readChunks({int chunkSize = 64 * 1024}) async* {
    _requireNotDisposed();
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    await flush();
    final path = _state == ArtifactState.promoted ? finalPath : partialPath;
    final file = File(path);
    if (!await file.exists()) {
      return;
    }
    final reader = await file.open();
    try {
      while (true) {
        final chunk = await reader.read(chunkSize);
        if (chunk.isEmpty) {
          break;
        }
        yield chunk;
      }
    } finally {
      await reader.close();
    }
  }

  Future<List<int>> readPrefix([int maxBytes = 12]) async {
    _requireNotDisposed();
    if (maxBytes <= 0) {
      return const <int>[];
    }
    final path = _state == ArtifactState.promoted ? finalPath : partialPath;
    final file = File(path);
    if (!await file.exists()) {
      return const <int>[];
    }
    final length = await file.length();
    if (length == 0) {
      return const <int>[];
    }
    final reader = await file.open();
    try {
      return await reader.read(length < maxBytes ? length : maxBytes);
    } finally {
      await reader.close();
    }
  }

  Future<Map<String, Object?>?> readMeta() async {
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

  Future<void> writeMeta(Map<String, Object?> value) async {
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

  Future<void> reset({bool deleteFinal = false}) async {
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
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _crc = Crc32();
    _committed = 0;
    _state = ArtifactState.empty;
  }

  Future<void> deleteAll() => reset(deleteFinal: true);

  Future<void> dispose() async {
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
        'checksum': checksum,
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
    await temp.writeAsString(jsonEncode(value), flush: true);
    await _replaceFile(temp, target);
  }

  Future<void> _replaceFile(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) {
        await target.delete();
      }
      await source.rename(target.path);
    }
  }

  Future<void> _rehash(File file) async {
    final crc = Crc32();
    var length = 0;
    await for (final chunk in file.openRead()) {
      crc.add(chunk);
      length += chunk.length;
    }
    _crc = crc;
    _committed = length;
  }

  Future<RandomAccessFile> _writer() async {
    final existing = _file;
    if (existing != null) {
      return existing;
    }
    final partial = File(partialPath);
    await partial.parent.create(recursive: true);
    final writer = await partial.open(mode: FileMode.append);
    final length = await writer.length();
    if (length != _committed) {
      await writer.close();
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'partial length changed from $_committed to $length',
      );
    }
    _file = writer;
    return writer;
  }

  Future<void> _closeWriter() async {
    await _writeTail;
    final writer = _file;
    _file = null;
    if (writer != null) {
      await writer.close();
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
