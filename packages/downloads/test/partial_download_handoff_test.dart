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
    final handoff = PartialDownloadHandoff(store: backend);
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
    expect(backend.partial[id]?.bytes, bytes);

    final restored = target.get(id);
    await handoff.restoreInto(restored);
    expect(restored.state, DownloadState.idle);
    expect(restored.committedLength, bytes.lengthInBytes);
    expect(restored.validators.etag, 'reader-etag');
    expect(restored.totalLength, 1024);
    expect(await restored.artifact.readBytes(), bytes);
  });

  test('physical partial never persists validators from an aliased provider',
      () async {
    final root = await Directory.systemTemp.createTemp('partial-validator-scope-');
    addTearDown(() async => root.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'physical',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('https://example.test/old.webp'),
    );
    final aliasedUri = Uri.parse('https://example.test/new.webp');
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);
    final session = registry.get(id);
    await session.restore();
    await session.bindResponse(
      validators: const Validators(etag: 'new-provider-v2'),
      validatorRequestUri: aliasedUri,
      totalLength: 1024,
    );
    final writer = session.acquireWriter();
    final bytes = Uint8List.fromList(List<int>.generate(320, (i) => i & 0xff));
    await session.append(writer, 0, bytes);
    await session.pause(writer);

    final backend = _PartialStore();
    final handoff = PartialDownloadHandoff(store: backend);
    expect(await handoff.persist(session), isTrue);

    expect(backend.partial[id]?.bytes, bytes);
    expect(backend.partial[id]?.validators.isEmpty, isTrue);
    expect(backend.partial[id]?.totalLength, 1024);
  });

  test('verified equivalent cold partial restores without copying exact entry',
      () async {
    final root = await Directory.systemTemp.createTemp('partial-equivalent-');
    addTearDown(() async => root.delete(recursive: true));
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'old',
        chapterId: 'chapter-old',
        pageId: 'page-old',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('https://example.test/old.webp'),
    );
    final newId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'new',
        chapterId: 'chapter-new',
        pageId: 'page-new',
      ),
      sourceRevision: 'new',
      canonicalUri: Uri.parse('https://example.test/new.webp'),
    );
    final bytes = Uint8List.fromList(List<int>.generate(384, (i) => i & 0xff));
    final backend = _PartialStore();
    backend.partial[oldId] = _StoredPartial(
      bytes: bytes,
      validators: const Validators(etag: 'old-version-etag'),
      totalLength: 1024,
    );
    final handoff = PartialDownloadHandoff(
      store: backend,
      equivalentCandidates: (id) => id == newId
          ? <DownloadId>[oldId]
          : const <DownloadId>[],
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);

    final session = registry.get(newId);
    await handoff.restoreInto(session);

    expect(session.committedLength, bytes.lengthInBytes);
    expect(session.validators.isEmpty, isTrue);
    expect(session.totalLength, 1024);
    expect(await session.artifact.readBytes(), bytes);
    expect(backend.partial.containsKey(newId), isFalse);
    expect(backend.partial.containsKey(oldId), isTrue);
  });
  test('cold partial hydration uses the shared persistent read scheduler', () async {
    final root = await Directory.systemTemp.createTemp('partial-read-scheduler-');
    addTearDown(() async => root.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'scheduler',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/scheduler.webp'),
    );
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    var activeWhileReading = 0;
    final backend = _PartialStore(
      onRead: () => activeWhileReading = scheduler.activeCount,
    );
    final bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xff));
    backend.partial[id] = _StoredPartial(
      bytes: bytes,
      validators: const Validators(),
      totalLength: bytes.lengthInBytes + 1024,
    );
    final handoff = PartialDownloadHandoff(
      store: backend,
      readScheduler: scheduler,
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);

    final session = registry.get(id);
    await handoff.restoreInto(session);

    expect(activeWhileReading, 1);
    expect(scheduler.activeCount, 0);
    expect(session.committedLength, bytes.lengthInBytes);
  });

}

final class _PartialStore implements PartialDownloadStore {
  _PartialStore({this.onRead});

  final void Function()? onRead;
  final Map<DownloadId, _StoredPartial> partial =
      <DownloadId, _StoredPartial>{};

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) async {
    final stored = partial[id];
    if (stored == null) return null;
    return PartialDownloadEntry(
      length: stored.bytes.lengthInBytes,
      validators: stored.validators,
      totalLength: stored.totalLength,
      open: ({required int start}) async* {
        onRead?.call();
        yield Uint8List.sublistView(stored.bytes, start);
      },
    );
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
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
  Future<void> invalidatePartialDownload(DownloadId id) async {
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
