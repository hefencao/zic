import 'dart:io';
import 'dart:typed_data';

import 'package:downloads/downloads.dart';
import 'package:downloads/src/artifact_bytes.dart' show openArtifactByteRangeReader;
import 'package:test/test.dart';

void main() {
  test('missing POSIX artifact reports typed read failure before bytes', () async {
    final root = await Directory.systemTemp.createTemp('zic-artifact-read-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/missing.bin';

    await expectLater(
      const LocalArtifactBytes().readChunks(path, start: 7).toList(),
      throwsA(
        isA<ArtifactReadFailure>()
            .having((failure) => failure.kind, 'kind', ArtifactReadFailureKind.missing)
            .having((failure) => failure.failedOffset, 'failedOffset', 7)
            .having((failure) => failure.bytesEmitted, 'bytesEmitted', 0),
      ),
    );
  });

  test('short POSIX body reports the exact emitted prefix', () async {
    final root = await Directory.systemTemp.createTemp('zic-artifact-short-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/body.bin');
    await file.writeAsBytes(<int>[1, 2, 3, 4]);

    final chunks = <int>[];
    Object? failure;
    try {
      await for (final chunk
          in const LocalArtifactBytes().readChunks(file.path, start: 0, endExclusive: 8)) {
        chunks.addAll(chunk);
      }
    } catch (error) {
      failure = error;
    }

    expect(chunks, <int>[1, 2, 3, 4]);
    expect(
      failure,
      isA<ArtifactReadFailure>()
          .having((value) => value.kind, 'kind', ArtifactReadFailureKind.shortRead)
          .having((value) => value.failedOffset, 'failedOffset', 4)
          .having((value) => value.bytesEmitted, 'bytesEmitted', 4)
          .having((value) => value.expectedLength, 'expectedLength', 8)
          .having((value) => value.observedLength, 'observedLength', 4),
    );
  });

  test('SAF adapter failure retains typed cause and read offset', () async {
    const tree = 'content://tree/root';
    final bytes = SafArtifactBytes(
      const _FailingSafIo(ArtifactReadFailureKind.accessDenied),
      treeUri: tree,
    );
    final path = encodeSafRecordPath(treeUri: tree, relativePath: 'page.webp');

    await expectLater(
      bytes.readChunks(path, start: 11, endExclusive: 20).toList(),
      throwsA(
        isA<ArtifactReadFailure>()
            .having((failure) => failure.kind, 'kind', ArtifactReadFailureKind.accessDenied)
            .having((failure) => failure.accessLocator, 'accessLocator', path)
            .having((failure) => failure.failedOffset, 'failedOffset', 11)
            .having((failure) => failure.bytesEmitted, 'bytesEmitted', 0),
      ),
    );
  });

  test('SAF reusable range reader keeps one descriptor across ranges', () async {
    const tree = 'content://tree/reuse';
    final io = _CountingSafIo(Uint8List.fromList(List<int>.generate(32, (i) => i)));
    final bytes = SafArtifactBytes(io, treeUri: tree);
    final path = encodeSafRecordPath(treeUri: tree, relativePath: 'page.webp');

    final reader = await openArtifactByteRangeReader(bytes, path);
    expect(reader, isNotNull);
    expect(reader!.accessMode, 'saf');
    expect(await reader.length(), 32);
    expect(await reader.readRange(0, 8), orderedEquals(List<int>.generate(8, (i) => i)));
    expect(await reader.readRange(8, 16), orderedEquals(List<int>.generate(8, (i) => i + 8)));
    expect(io.openCalls, 1, reason: 'READY length proof and ranges retain one SAF descriptor');
    expect(io.readAtCalls, 2,
        reason: 'each range is one non-interleavable SAF provider operation');
    expect(io.seekCalls, 0);
    expect(io.readCalls, 0);

    await reader.close();
    expect(io.closeCalls, 1);
  });
}

final class _CountingSafIo implements SafTreeIo, SafTreeRandomRead {
  _CountingSafIo(this.bytes);

  final Uint8List bytes;
  int openCalls = 0;
  int seekCalls = 0;
  int readCalls = 0;
  int readAtCalls = 0;
  int closeCalls = 0;
  int _position = 0;

  @override
  Future<int?> open(String relativePath, {SafWriteMode? mode}) async {
    openCalls++;
    _position = 0;
    return 1;
  }

  @override
  Future<Uint8List> read(int handle, int length) async {
    readCalls++;
    final end = (_position + length).clamp(_position, bytes.length).toInt();
    final value = Uint8List.sublistView(bytes, _position, end);
    _position = end;
    return value;
  }

  @override
  Future<Uint8List> readAt(int handle, int position, int length) async {
    readAtCalls++;
    final end = (position + length).clamp(position, bytes.length).toInt();
    return Uint8List.sublistView(bytes, position, end);
  }

  @override
  Future<void> seek(int handle, int position) async {
    seekCalls++;
    _position = position;
  }

  @override
  Future<void> close(int handle) async {
    closeCalls++;
  }

  @override
  Future<int?> length(int handle) async => bytes.length;

  @override
  Future<bool> exists(String relativePath) async => true;

  @override
  Future<void> write(int handle, Uint8List bytes) => throw UnimplementedError();

  @override
  Future<bool> delete(String relativePath) => throw UnimplementedError();

  @override
  Future<bool> rename(String relativePath, String newRelativePath) =>
      throw UnimplementedError();

  @override
  Future<List<SafTreeFile>> list(String relativePath) => throw UnimplementedError();
}

final class _FailingSafIo implements SafTreeIo {
  const _FailingSafIo(this.kind);

  final ArtifactReadFailureKind kind;

  @override
  Future<int?> open(String relativePath, {SafWriteMode? mode}) async {
    throw SafTreeAccessFailure(kind: kind, operation: 'open');
  }

  @override
  Future<Uint8List> read(int handle, int length) => throw UnimplementedError();

  @override
  Future<void> write(int handle, Uint8List bytes) => throw UnimplementedError();

  @override
  Future<int?> length(int handle) => throw UnimplementedError();

  @override
  Future<void> seek(int handle, int position) => throw UnimplementedError();

  @override
  Future<void> close(int handle) async {}

  @override
  Future<bool> delete(String relativePath) => throw UnimplementedError();

  @override
  Future<bool> rename(String relativePath, String newRelativePath) =>
      throw UnimplementedError();

  @override
  Future<bool> exists(String relativePath) => throw UnimplementedError();

  @override
  Future<List<SafTreeFile>> list(String relativePath) => throw UnimplementedError();
}
