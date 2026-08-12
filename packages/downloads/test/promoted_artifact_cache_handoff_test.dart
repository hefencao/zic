import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('commits bytes only after the session promotes its artifact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final handoff = PromotedArtifactCacheHandoff(cache: cache);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);
    final bytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5]);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'fixture-r1',
        loadBytes: () async => bytes,
      ),
    });

    expect(backend.values, isEmpty);
    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(registry.sessions);

    expect(session.state, DownloadState.promoted);
    expect(backend.values[id], bytes);
  });

  test('memory-only hit still writes through to the backend', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-memory-only-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://memory-only-promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'memory-only-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final bytes = Uint8List.fromList(<int>[1, 6, 1, 8]);
    cache.remember(id: id, bytes: bytes);
    final handoff = PromotedArtifactCacheHandoff(cache: cache);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'fixture-r1',
        loadBytes: () async => bytes,
      ),
    });

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(registry.sessions);

    expect(backend.values[id], bytes);
  });

  test('source-resident promotion defers durable materialization until required',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-resident-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://resident-promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'resident-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: SystemClock(),
      traceSink: trace,
      residentReplaySource: (session, endExclusive) async =>
          Stream<List<int>>.value(bytes.sublist(0, endExclusive)),
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);

    await DownloadJob(
      transport: _ResidentTransport(bytes),
      session: session,
    ).run();
    await handoff.drain(registry.sessions);

    expect(session.residentCacheBacked, isTrue);
    expect(session.residentSource, 'reopenable-immutable-source');
    expect(session.artifact.committedLength, 0);
    expect(backend.values, isEmpty);
    expect(
      trace.events.any(
        (event) => event.payload['action'] == 'defer-resident-source',
      ),
      isTrue,
    );

    await handoff.persist(session);
    expect(backend.values[id], bytes);
    expect(
      trace.events.any(
        (event) => event.payload['action'] == 'stored-resident-source',
      ),
      isTrue,
    );
  });

  test('skips materializing a session artifact already present durably',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-existing-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://existing-promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'existing-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final backend = _ExistingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: SystemClock(),
      traceSink: trace,
      sessionId: 'reader-existing',
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);
    final bytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8]);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'fixture-r1',
        loadBytes: () async => bytes,
      ),
    });

    backend.existing = Uint8List(bytes.lengthInBytes);
    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(<DownloadSession>[session]);
    await handoff.drain(<DownloadSession>[session]);

    expect(backend.storeCalls, 0);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['action'] == 'skip-existing',
      ),
      hasLength(1),
    );
    final event = trace.events.singleWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['action'] == 'skip-existing',
    );
    expect(event.payload['bytes'], bytes.lengthInBytes);
  });
  test('verified equivalent durable artifact avoids Reader-side exact copy',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-equivalent-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'old-comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('memory://old-equivalent-page'),
    );
    final newId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'new-comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'new',
      canonicalUri: Uri.parse('memory://new-equivalent-page'),
    );
    final bytes = Uint8List.fromList(<int>[8, 6, 7, 5, 3, 0, 9]);
    final backend = _RecordingArtifactStore()
      ..values[oldId] = Uint8List.fromList(bytes);
    final cache = ArtifactCacheManager(backend: backend)
      ..linkEquivalent(first: oldId, second: newId);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: SystemClock(),
      traceSink: trace,
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(newId);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      newId.canonicalUri: LoaderTransportSource(
        revision: 'fixture-new',
        loadBytes: () async => bytes,
      ),
    });

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(registry.sessions);

    expect(backend.values[newId], isNull);
    expect((await cache.readForeground(newId))?.bytes, bytes);
    expect(
      trace.events.any(
        (event) =>
            event.payload['action'] == 'skip-verified-equivalent-durable',
      ),
      isTrue,
    );

    await handoff.persist(session);
    expect(backend.values[newId], bytes);
  });

}

final class _RecordingArtifactStore implements ArtifactCacheBackend {
  final Map<DownloadId, Uint8List> values = <DownloadId, Uint8List>{};

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    final bytes = values[id];
    if (bytes == null) return null;
    return _entry(bytes);
  }


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    values.remove(id);
  }
}

final class _ExistingArtifactStore implements ArtifactCacheBackend {
  Uint8List? existing;
  int storeCalls = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    final bytes = existing;
    return bytes == null ? null : _entry(bytes);
  }


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    storeCalls++;
    existing = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    existing = null;
  }
}

ArtifactCacheStreamEntry _entry(Uint8List bytes) => ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.sublistView(
          bytes,
          start,
          endExclusive ?? bytes.lengthInBytes,
        );
      },
      readAll: () async => bytes,
    );


final class _ResidentTransport implements Transport {
  const _ResidentTransport(this.bytes);

  final Uint8List bytes;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: Stream<List<int>>.value(bytes),
        statusCode: 200,
        rangeStart: 0,
        totalLength: bytes.lengthInBytes,
        disposition: ByteResponseDisposition.durableImmutable,
      );
}
