import 'dart:io';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('local file seals ingress without staging an artifact', () async {
    final temp = await Directory.systemTemp.createTemp('download_ingress_');
    addTearDown(() async => temp.delete(recursive: true));
    final bytes = 'RIFF....WEBPpayload'.codeUnits;
    final input = File('${temp.path}/input.webp');
    await input.writeAsBytes(bytes);

    final factory = _Factory();
    final ingress = Ingress(factory: factory, maxBytes: 1024);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: input.uri,
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/cache/page.part',
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test-1:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);

    await DownloadJob(transport: const FileTransport(), session: session).run();

    expect(session.state, DownloadState.promoted);
    expect(session.residentBodyBacked, isTrue);
    expect(File(session.artifact.partialPath).existsSync(), isFalse);
    expect(File(session.artifact.finalPath).existsSync(), isFalse);
    expect(factory.created.single.bytes, bytes);
    expect(factory.created.single.sealed, isTrue);
    expect(ingress.snapshot.kind, ContentKind.webp);
  });

  test('durable cache response seals ingress without staging an artifact',
      () async {
    final temp = await Directory.systemTemp.createTemp('durable_ingress_');
    addTearDown(() async => temp.delete(recursive: true));
    final bytes = 'RIFF....WEBPdurable-cache'.codeUnits;
    final factory = _Factory();
    final ingress = Ingress(factory: factory, maxBytes: 1024);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'durable',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('cache://page/durable'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/cache/page.part',
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test-2:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);

    final result = await DownloadJob(
      transport: _DurableTransport(bytes),
      session: session,
    ).run();

    expect(result.state, DownloadState.promoted);
    expect(result.committedLength, bytes.length);
    expect(session.residentBodyBacked, isTrue);
    expect(factory.created.single.bytes, bytes);
    expect(factory.created.single.sealed, isTrue);
    expect(File(session.artifact.partialPath).existsSync(), isFalse);
    expect(File(session.artifact.finalPath).existsSync(), isFalse);
  });

  test('failed durable cache ingress resets the session for retry', () async {
    final temp = await Directory.systemTemp.createTemp('durable_failure_');
    addTearDown(() async => temp.delete(recursive: true));
    final ingress = Ingress(factory: _Factory(), maxBytes: 1024);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'durable-failure',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('cache://page/failure'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/cache/page.part',
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test-3:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);

    await expectLater(
      DownloadJob(
        transport: const _FailingDurableTransport(),
        session: session,
      ).run(),
      throwsA(isA<StateError>()),
    );

    expect(session.state, DownloadState.idle);
    expect(session.committedLength, 0);
    expect(session.residentBodyBacked, isFalse);
  });

  test('source listener failures do not fail the authoritative download', () async {
    final temp = await Directory.systemTemp.createTemp('source_listener_');
    addTearDown(() async => temp.delete(recursive: true));
    final bytes = 'RIFF....WEBPpayload'.codeUnits;
    final input = File('${temp.path}/input.webp');
    await input.writeAsBytes(bytes);

    final ingress = Ingress(factory: _Factory(), maxBytes: 1024);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'listener',
        ),
        sourceRevision: 'r1',
        canonicalUri: input.uri,
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/cache/page.part',
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test-4:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);
    projection.addSourceListener((_) => throw StateError('listener failed'));

    final result = await DownloadJob(
      transport: const FileTransport(),
      session: session,
    ).run();

    expect(result.state, DownloadState.promoted);
    expect(session.residentBodyBacked, isTrue);
    expect(File(result.artifact.partialPath).existsSync(), isFalse);
    expect(File(result.artifact.finalPath).existsSync(), isFalse);
    await session.dispose();
  });

  test('restoring a promoted WebP rebuilds the encoded source', () async {
    final temp = await Directory.systemTemp.createTemp('restore_ingress_');
    addTearDown(() async => temp.delete(recursive: true));
    final bytes = 'RIFF....WEBPrestored'.codeUnits;
    final finalPath = '${temp.path}/cache/page.webp';
    await File(finalPath).create(recursive: true);
    await File(finalPath).writeAsBytes(bytes);

    final factory = _Factory();
    final ingress = Ingress(factory: factory, maxBytes: 1024);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'restored',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.file(finalPath),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/cache/page.part',
        finalPath: finalPath,
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test-5:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);

    await session.restore();

    expect(session.state, DownloadState.promoted);
    expect(factory.created.single.bytes, bytes);
    expect(factory.created.single.sealed, isTrue);
  });
}


final class _DurableTransport implements Transport {
  _DurableTransport(this.bytes);

  final List<int> bytes;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: Stream<List<int>>.fromIterable(<List<int>>[
          bytes.sublist(0, bytes.length ~/ 2),
          bytes.sublist(bytes.length ~/ 2),
        ]),
        statusCode: 200,
        rangeStart: 0,
        totalLength: bytes.length,
        disposition: ByteResponseDisposition.durableImmutable,
      );
}

final class _FailingDurableTransport implements Transport {
  const _FailingDurableTransport();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: (() async* {
          yield <int>[1, 2, 3, 4];
          throw StateError('fixture durable stream failure');
        })(),
        statusCode: 200,
        rangeStart: 0,
        totalLength: 8,
        disposition: ByteResponseDisposition.durableImmutable,
      );
}

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 0;
}

final class _Factory implements SourceFactory {
  final List<_Source> created = <_Source>[];

  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    final source = _Source(epoch: epoch, maxBytes: maxBytes);
    created.add(source);
    return source;
  }
}

final class _Source implements EncodedSource {
  _Source({required this.epoch, required this.maxBytes});

  @override
  int epoch;
  final int maxBytes;
  final List<int> bytes = <int>[];

  @override
  int get length => bytes.length;

  @override
  bool sealed = false;

  @override
  SourceKind get kind => bytes.length >= 12 ? SourceKind.webp : SourceKind.unknown;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    if (epoch != this.epoch) {
      return SourceStatus.staleEpoch;
    }
    if (offset != this.bytes.length) {
      return SourceStatus.invalidOffset;
    }
    if (this.bytes.length + bytes.length > maxBytes) {
      return SourceStatus.budget;
    }
    this.bytes.addAll(bytes);
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    bytes.clear();
    sealed = false;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) {
    if (epoch != this.epoch) {
      return SourceStatus.staleEpoch;
    }
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}
