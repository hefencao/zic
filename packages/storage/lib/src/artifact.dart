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
  });

  final ArtifactState state;
  final int committedLength;
  final String checksum;
  final String partialPath;
  final String finalPath;
}

final class Artifact {
  Artifact({
    required this.partialPath,
    required this.finalPath,
    String? metaPath,
  }) : metaPath = metaPath ?? '$partialPath.meta';

  final String partialPath;
  final String finalPath;
  final String metaPath;

  ArtifactState _state = ArtifactState.empty;
  RandomAccessFile? _file;
  Crc32 _crc = Crc32();
  int _committed = 0;

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
      );

  Future<ArtifactSnapshot> restore() async {
    _requireNotDisposed();
    await _closeWriter();

    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await _rehash(finalFile);
      _state = ArtifactState.promoted;
      return snapshot;
    }

    final partial = File(partialPath);
    if (await partial.exists()) {
      await _rehash(partial);
      _state = ArtifactState.partial;
      _file = await partial.open(mode: FileMode.append);
      return snapshot;
    }

    await partial.parent.create(recursive: true);
    _file = await partial.open(mode: FileMode.write);
    _crc = Crc32();
    _committed = 0;
    _state = ArtifactState.partial;
    return snapshot;
  }

  Future<void> append(int offset, List<int> bytes) async {
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
    final writer = _file;
    if (writer == null) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'partial artifact has no open writer',
      );
    }
    await writer.writeFrom(bytes);
    _crc.add(bytes);
    _committed += bytes.length;
  }

  Future<void> flush() async {
    _requireNotDisposed();
    await _file?.flush();
  }

  Future<void> pause() async {
    _requireState(ArtifactState.partial);
    await flush();
    await _closeWriter();
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
    _state = ArtifactState.sealed;
    return snapshot;
  }

  Future<ArtifactSnapshot> promote() async {
    _requireState(ArtifactState.sealed);
    final partial = File(partialPath);
    final target = File(finalPath);
    await target.parent.create(recursive: true);

    if (await target.exists()) {
      final existingCrc = Crc32();
      var existingLength = 0;
      await for (final chunk in target.openRead()) {
        existingCrc.add(chunk);
        existingLength += chunk.length;
      }
      if (existingLength != _committed || existingCrc.hex != checksum) {
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

    for (final path in <String>[metaPath, '$metaPath.tmp']) {
      final metadata = File(path);
      if (await metadata.exists()) {
        await metadata.delete();
      }
    }
    _state = ArtifactState.promoted;
    return snapshot;
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
      return reader.read(length < maxBytes ? length : maxBytes);
    } finally {
      await reader.close();
    }
  }

  Future<Map<String, Object?>?> readMeta() async {
    _requireNotDisposed();
    final file = File(metaPath);
    if (!await file.exists()) {
      return null;
    }
    Object? value;
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

  Future<void> writeMeta(Map<String, Object?> value) async {
    _requireNotDisposed();
    final target = File(metaPath);
    await target.parent.create(recursive: true);
    final temp = File('$metaPath.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    try {
      await temp.rename(metaPath);
    } on FileSystemException {
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(metaPath);
    }
  }

  Future<void> reset({bool deleteFinal = false}) async {
    _requireNotDisposed();
    await _closeWriter();
    for (final path in <String>[
      partialPath,
      metaPath,
      '$metaPath.tmp',
      if (deleteFinal) finalPath,
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

  Future<void> _closeWriter() async {
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
