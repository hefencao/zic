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

    await DownloadJob(transport: transport, session: session).run();
    backend.existing = Uint8List(bytes.lengthInBytes);
    await handoff.drain(<DownloadSession>[session]);

    expect(backend.storeCalls, 0);
    final event = trace.events.singleWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['action'] == 'skip-existing',
    );
    expect(event.payload['bytes'], bytes.lengthInBytes);
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
  Future<Uint8List?> readArtifact(DownloadId id) async => values[id];

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
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
  Future<Uint8List?> readArtifact(DownloadId id) async => existing;

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    storeCalls++;
    existing = Uint8List.fromList(bytes);
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
