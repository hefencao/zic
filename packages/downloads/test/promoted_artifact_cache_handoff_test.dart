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
    final cache = _RecordingArtifactStore();
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

    expect(cache.values, isEmpty);
    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(registry.sessions);

    expect(session.state, DownloadState.promoted);
    expect(cache.values[id], bytes);
  });
}

final class _RecordingArtifactStore implements ArtifactCacheStore {
  final Map<DownloadId, Uint8List> values = <DownloadId, Uint8List>{};

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
