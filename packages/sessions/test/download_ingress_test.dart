import 'dart:io';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test(
    'resident initial hydration uses generation direct file in background',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'resident_direct_file_hydration_',
      );
      addTearDown(() async => temp.delete(recursive: true));
      final bytes = <int>[
        ...'RIFF....WEBP'.codeUnits,
        ...List<int>.generate(320 * 1024 - 12, (index) => index & 0xff),
      ];
      final file = File('${temp.path}/resident.webp');
      await file.writeAsBytes(bytes);
      final id = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'resident-direct-file',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.file(file.path),
      );
      final session = DownloadSession(
        id: id,
        artifact: Artifact(
          partialPath: '${temp.path}/cache/page.part',
          finalPath: '${temp.path}/cache/page.webp',
        ),
        clock: _Clock(),
      );
      session.bindResidentImmutableAuthority(
        validators: const Validators(),
        totalLength: bytes.length,
        bodyAuthority: ByteResponseBodyAuthority.artifactCache,
        metadataPrefix: bytes.sublist(0, 64),
        residentReplayDirectFilePath: file.path,
        residentReplayAccessMode: 'direct',
      );
      final factory = _BackgroundFileFactory();
      final sources = SourcePool(
        factory: factory,
        budgetFor: (_) => bytes.length + 1024,
      );
      var fallbackRangeCalls = 0;
      final registry = DownloadIngressProjectionRegistry(
        sources: sources,
        scopePrefix: 'resident-direct-file',
        residentReplayRangeSourceWithControl:
            (physical, start, endExclusive, {required control}) async {
              fallbackRangeCalls++;
              return Stream<List<int>>.value(
                bytes.sublist(start, endExclusive),
              );
            },
      );
      addTearDown(registry.dispose);

      final projection = registry.get(session);
      await registry.settled(id);

      expect(
        fallbackRangeCalls,
        0,
        reason: 'a direct immutable file must not be replayed through Dart',
      );
      expect(factory.created, hasLength(1));
      expect(factory.created.single.directFileRangeCalls, 1);
      expect(
        factory.created.single.lastControl,
        isNotNull,
        reason: 'background source execution must retain ingress rank/cancel control',
      );
      expect(projection.snapshot.length, 256 * 1024);
      expect(
        factory.created.single.bytes,
        orderedEquals(bytes.sublist(0, 256 * 1024)),
      );
      expect(
        projection.snapshot.sourceReady,
        isTrue,
        reason: 'the synchronized direct-file rebuild publishes one ready edge',
      );
    },
  );

  test(
    'resident initial hydration falls back when no direct file is bound',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'resident_replay_fallback_',
      );
      addTearDown(() async => temp.delete(recursive: true));
      final bytes = <int>[
        ...'RIFF....WEBP'.codeUnits,
        ...List<int>.generate(320 * 1024 - 12, (index) => index & 0xff),
      ];
      final id = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'resident-replay-fallback',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('content://reader/resident-replay-fallback'),
      );
      final session = DownloadSession(
        id: id,
        artifact: Artifact(
          partialPath: '${temp.path}/cache/page.part',
          finalPath: '${temp.path}/cache/page.webp',
        ),
        clock: _Clock(),
      );
      session.bindResidentImmutableAuthority(
        validators: const Validators(),
        totalLength: bytes.length,
        bodyAuthority: ByteResponseBodyAuthority.artifactCache,
        metadataPrefix: bytes.sublist(0, 64),
        residentReplayAccessMode: 'saf',
      );
      final factory = _BackgroundFileFactory();
      final sources = SourcePool(
        factory: factory,
        budgetFor: (_) => bytes.length + 1024,
      );
      var fallbackRangeCalls = 0;
      final registry = DownloadIngressProjectionRegistry(
        sources: sources,
        scopePrefix: 'resident-fallback',
        residentReplayRangeSourceWithControl:
            (physical, start, endExclusive, {required control}) async {
              fallbackRangeCalls++;
              return Stream<List<int>>.value(
                bytes.sublist(start, endExclusive),
              );
            },
      );
      addTearDown(registry.dispose);

      final projection = registry.get(session);
      await registry.settled(id);

      expect(fallbackRangeCalls, 1);
      expect(factory.created.single.directFileRangeCalls, 0);
      expect(projection.snapshot.length, 256 * 1024);
      expect(
        factory.created.single.bytes,
        orderedEquals(bytes.sublist(0, 256 * 1024)),
      );
    },
  );

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
  },
  );

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
  },
  );

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

  test(
      'detached Reader ingress cannot turn promoted restore into network fallback',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('restore_detached_ingress_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final bytes = 'RIFF....WEBPrestored-detach-race'.codeUnits;
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
          pageId: 'restored-detach-race',
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
      scopeId: 'test-detach-race:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);
    factory.onAppend = () {
      expect(session.detachIngressProjection(projection.scopeId), isTrue);
      projection.detach();
      ingress.dispose();
    };

    final restored = await session.restore();

    expect(restored.state, DownloadState.promoted);
    expect(restored.committedLength, bytes.length);
    expect(session.snapshot.ingressProjectionCount, 0);
  },
  );
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
  void Function()? onAppend;

  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    final source = _Source(
      epoch: epoch,
      maxBytes: maxBytes,
      onAppend: onAppend,
    );
    created.add(source);
    return source;
  }
}

final class _BackgroundFileFactory implements SourceFactory {
  final List<_BackgroundFileSource> created = <_BackgroundFileSource>[];

  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    final source = _BackgroundFileSource(epoch: epoch, maxBytes: maxBytes);
    created.add(source);
    return source;
  }
}

final class _BackgroundFileSource
    implements
        EncodedSource,
        BackgroundWritableEncodedSource,
        BackgroundFileRangeWritableEncodedSource {
  _BackgroundFileSource({required this.epoch, required this.maxBytes});

  @override
  int epoch;
  final int maxBytes;
  final List<int> bytes = <int>[];
  int directFileRangeCalls = 0;
  TaskControl? lastControl;

  @override
  int get length => bytes.length;

  @override
  bool sealed = false;

  @override
  SourceKind get kind =>
      bytes.length >= 12 ? SourceKind.webp : SourceKind.unknown;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    if (epoch != this.epoch) return SourceStatus.staleEpoch;
    if (offset != this.bytes.length) return SourceStatus.invalidOffset;
    if (this.bytes.length + bytes.length > maxBytes) return SourceStatus.budget;
    this.bytes.addAll(bytes);
    return SourceStatus.ok;
  }

  @override
  Future<SourceStatus> appendInBackground({
    required int epoch,
    required int offset,
    required List<int> bytes,
    TaskControl? control,
  }) async {
    lastControl = control;
    return append(epoch: epoch, offset: offset, bytes: bytes);
  }

  @override
  Future<SourceStatus> appendFileRangeInBackground({
    required int epoch,
    required int offset,
    required String path,
    required int fileOffset,
    required int length,
    TaskControl? control,
  }) async {
    lastControl = control;
    directFileRangeCalls++;
    final body = await File(path).readAsBytes();
    return append(
      epoch: epoch,
      offset: offset,
      bytes: body.sublist(fileOffset, fileOffset + length),
    );
  }

  @override
  Future<SourceStatus> reserveExpectedLengthInBackground({
    required int epoch,
    required int length,
    TaskControl? control,
  }) async {
    lastControl = control;
    return epoch == this.epoch ? SourceStatus.ok : SourceStatus.staleEpoch;
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
    if (epoch != this.epoch) return SourceStatus.staleEpoch;
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}

final class _Source implements EncodedSource {
  _Source({
    required this.epoch,
    required this.maxBytes,
    this.onAppend});

  @override
  int epoch;
  final int maxBytes;
  void Function()? onAppend;
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
    final callback = onAppend;
    onAppend = null;
    callback?.call();
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
