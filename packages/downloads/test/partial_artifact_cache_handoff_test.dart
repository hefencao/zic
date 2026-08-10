import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('partial survives Reader-session workspace replacement without promotion',
      () async {
    final firstRoot = await Directory.systemTemp.createTemp('partial-source-');
    final secondRoot = await Directory.systemTemp.createTemp('partial-target-');
    addTearDown(() async {
      await firstRoot.delete(recursive: true);
      await secondRoot.delete(recursive: true);
    });
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
    );
    final backend = _PartialStore();
    final cache = ArtifactCacheManager(backend: backend);
    final handoff = PartialArtifactCacheHandoff(cache: cache);
    final first = DownloadRegistry(
      layout: CacheLayout(firstRoot.path),
      clock: SystemClock(),
    );
    final target = DownloadRegistry(
      layout: CacheLayout(secondRoot.path),
      clock: SystemClock(),
    );
    addTearDown(() async {
      await first.dispose();
      await target.dispose();
    });

    final source = first.get(id);
    await source.restore();
    await source.bindResponse(
      validators: const Validators(etag: 'reader-etag'),
      totalLength: 1024,
    );
    final writer = source.acquireWriter();
    final bytes = Uint8List.fromList(List<int>.generate(320, (i) => i & 0xff));
    await source.append(writer, 0, bytes);
    await source.pause(writer);

    await handoff.drain(<DownloadSession>[source]);
    expect(backend.promoted, isEmpty);
    expect(backend.partial[id]?.bytes, bytes);

    final restored = target.get(id);
    await handoff.restoreInto(restored);
    expect(restored.state, DownloadState.idle);
    expect(restored.committedLength, bytes.lengthInBytes);
    expect(restored.validators.etag, 'reader-etag');
    expect(restored.totalLength, 1024);
    expect(await restored.artifact.readBytes(), bytes);
  });
}

final class _PartialStore
    implements ArtifactCacheBackend, PartialArtifactCacheBackend {
  final Map<DownloadId, Uint8List> promoted = <DownloadId, Uint8List>{};
  final Map<DownloadId, _StoredPartial> partial =
      <DownloadId, _StoredPartial>{};

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async =>
      null;

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    promoted[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    promoted.remove(id);
  }

  @override
  Future<PartialArtifactCacheEntry?> openPartialArtifact(DownloadId id) async {
    final stored = partial[id];
    if (stored == null) return null;
    return PartialArtifactCacheEntry(
      length: stored.bytes.lengthInBytes,
      validators: stored.validators,
      totalLength: stored.totalLength,
      open: ({required int start}) async* {
        yield Uint8List.sublistView(stored.bytes, start);
      },
    );
  }

  @override
  Future<void> storePartialArtifact({
    required DownloadId id,
    required PartialArtifactCacheEntry entry,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in entry.open(start: 0)) {
      builder.add(chunk);
    }
    partial[id] = _StoredPartial(
      bytes: builder.takeBytes(),
      validators: entry.validators,
      totalLength: entry.totalLength,
    );
  }

  @override
  Future<void> invalidatePartialArtifact(DownloadId id) async {
    partial.remove(id);
  }
}

final class _StoredPartial {
  const _StoredPartial({
    required this.bytes,
    required this.validators,
    required this.totalLength,
  });

  final Uint8List bytes;
  final Validators validators;
  final int? totalLength;
}
