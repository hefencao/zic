import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:domain/domain.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('file body reads bounded chunks and releases after the consumer exits',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-body-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = Uint8List.fromList(List<int>.generate(150000, (i) => i % 251));
    final file = await File('${root.path}/verified.lease').writeAsBytes(bytes);
    var releases = 0;
    final body = await ExternalPluginRuntimeFileBody.openVerified(
      reference: _reference(bytes),
      path: file.path,
      release: () async { releases++; await file.delete(); },
    );
    final chunks = await body.open().toList();
    expect(chunks.expand((chunk) => chunk), bytes);
    expect(chunks.every((chunk) => chunk.length <= 64 * 1024), isTrue);
    expect(releases, 1);
    expect(await file.exists(), isFalse);
    await body.dispose();
    expect(releases, 1);
  });

  test('range reads keep the sealed body validator and metadata', () async {
    final root = await Directory.systemTemp.createTemp('zic-body-range-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = Uint8List.fromList(List<int>.generate(200, (i) => i));
    final file = await File('${root.path}/verified.lease').writeAsBytes(bytes);
    final body = await ExternalPluginRuntimeFileBody.openVerified(
      reference: _reference(bytes), path: file.path,
      release: () => file.delete().then((_) {}),
    );
    expect(body.validator, _reference(bytes).validator);
    expect(body.metadataPrefix, bytes.sublist(0, 64));
    expect((await body.open(start: 73, end: 112).toList()).expand((c) => c),
        bytes.sublist(73, 112));
    expect(await file.exists(), isFalse);
  });

  test('dispose before subscription closes once and prevents new readers',
      () async {
    final file = _BlockedFile();
    var releases = 0;
    final body = await _openBlocked(file, () async { releases++; });
    final first = body.dispose();
    expect(identical(first, body.dispose()), isTrue);
    await first;
    expect(file.closed, isTrue);
    expect(releases, 1);
    expect(file.readCalls, 0);
    expect(() => body.open(), throwsA(isA<Failure>().having(
      (e) => e.code, 'code', ErrorCode.cancelled,
    )));
  });

  test('cancel during a physical read joins its exit before close and release',
      () async {
    final file = _BlockedFile();
    var released = false;
    final body = await _openBlocked(file, () async {
      expect(file.readActive, isFalse);
      expect(file.closed, isTrue);
      released = true;
    });
    final iterator = StreamIterator<List<int>>(body.open());
    final pending = expectLater(iterator.moveNext(), throwsA(isA<Failure>().having(
      (e) => e.code, 'code', ErrorCode.cancelled,
    )));
    await file.started.future;
    final retirement = body.dispose();
    expect(identical(retirement, body.dispose()), isTrue);
    await Future<void>.value();
    expect(file.closed, isFalse);
    expect(released, isFalse);
    file.readResult.complete(Uint8List(128));
    await pending;
    await retirement;
    expect(released, isTrue);
    expect(file.readCalls, 1);
    await iterator.cancel();
  });

  test('stream cancellation also waits for an admitted physical read', () async {
    final file = _BlockedFile();
    var released = false;
    final body = await _openBlocked(file, () async { released = true; });
    final subscription = body.open().listen((_) {});
    await file.started.future;
    var cancelled = false;
    final cancellation = subscription.cancel().then((_) { cancelled = true; });
    await Future<void>.value();
    expect(cancelled, isFalse);
    expect(file.closed, isFalse);
    expect(released, isFalse);
    file.readResult.complete(Uint8List(128));
    await cancellation;
    expect(file.closed, isTrue);
    expect(released, isTrue);
  });

  test('failed physical read releases only after the read Future exits', () async {
    final file = _BlockedFile();
    var released = false;
    final body = await _openBlocked(file, () async { released = true; });
    final result = expectLater(body.open().toList(), throwsA(isA<FileSystemException>()));
    await file.started.future;
    file.readResult.completeError(const FileSystemException('read failed'));
    await result;
    expect(file.readActive, isFalse);
    expect(file.closed, isTrue);
    expect(released, isTrue);
  });

  test('claim/open failure releases the claimed file without publishing a body',
      () async {
    var released = false;
    await expectLater(ExternalPluginRuntimeFileBody.openVerified(
      reference: _reference(Uint8List(128)), path: '/missing/verified.lease',
      openFile: (_) => Future<RandomAccessFile>.error(
        const FileSystemException('open failed'),
      ),
      release: () async { released = true; },
    ), throwsA(isA<FileSystemException>()));
    expect(released, isTrue);
  });

  test('a body has one consumer and rejects an invalid range before any read',
      () async {
    final file = _BlockedFile();
    final body = await _openBlocked(file, () async {});
    expect(() => body.open(start: -1), throwsRangeError);
    body.open();
    expect(() => body.open(), throwsStateError);
    await body.dispose();
    expect(file.readCalls, 0);
  });
}

ExternalPluginRuntimeBodyFile _reference(Uint8List bytes) =>
    ExternalPluginRuntimeBodyFile.fromMessage(<String, Object?>{
      'bodyDelivery': 'sealed-file-v1',
      'ownerId': 'native-11111111-1111-1111-1111-111111111111',
      'bodyId': '22222222-2222-2222-2222-222222222222',
      'requestId': 'body-1', 'externalSourceId': 'fixture',
      'runtimeId': 'fixture-runtime',
      'authorityRevision': 'mihon-runtime-transform-v3:${'a' * 64}',
      'resourceUri': 'mihon:resource:unchanged',
      'byteLength': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'fnv64': '0123456789abcdef',
      'metadataPrefix': Uint8List.sublistView(bytes, 0, bytes.length < 64 ? bytes.length : 64),
    });

Future<ExternalPluginRuntimeFileBody> _openBlocked(
  _BlockedFile file, Future<void> Function() release,
) => ExternalPluginRuntimeFileBody.openVerified(
      reference: _reference(Uint8List(128)), path: '/verified/body.lease',
      openFile: (_) async => file, release: release,
    );

class _BlockedFile implements RandomAccessFile {
  final started = Completer<void>();
  final readResult = Completer<Uint8List>();
  bool readActive = false;
  bool closed = false;
  int readCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected file operation ${invocation.memberName}');

  @override
  Future<int> length() async => 128;

  @override
  Future<RandomAccessFile> setPosition(int position) async => this;

  @override
  Future<Uint8List> read(int count) {
    readCalls++;
    readActive = true;
    started.complete();
    return readResult.future.whenComplete(() { readActive = false; });
  }

  @override
  Future<void> close() async {
    expect(readActive, isFalse);
    closed = true;
  }
}
