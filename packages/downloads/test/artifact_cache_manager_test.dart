import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('defaults retain a VibeVenera-sized ten-page byte window', () {
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );

    expect(manager.memoryMaxEntries, 10);
    expect(manager.memoryMaxBytes, 256 * 1024 * 1024);
  });

  test('routes memory before backend and validates exact length', () async {
    final id = _id('memory');
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[1, 2, 3]),
    });
    final manager = ArtifactCacheManager(backend: backend);

    final first = await manager.readForeground(id);
    final second = await manager.readForeground(id);

    expect(first?.memoryHit, isFalse);
    expect(second?.memoryHit, isTrue);
    expect(backend.openCalls, 1);
    expect(await manager.contains(id: id, expectedLength: 3), isTrue);
    expect(await manager.contains(id: id, expectedLength: 4), isFalse);
    expect(await manager.containsBackend(id: id, expectedLength: 3), isTrue);
  });

  test('memory visibility does not masquerade as backend persistence', () async {
    final id = _id('memory-only');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    manager.remember(id: id, bytes: Uint8List.fromList(<int>[1, 2, 3]));

    expect(await manager.contains(id: id, expectedLength: 3), isTrue);
    expect(
      await manager.containsBackend(id: id, expectedLength: 3),
      isFalse,
    );
  });

  test('joins concurrent foreground materialization in the manager', () async {
    final id = _id('join');
    final gate = Completer<void>();
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[4, 5, 6]),
    }, readGate: gate);
    final manager = ArtifactCacheManager(backend: backend);

    final first = manager.readForeground(id);
    final second = manager.readForeground(id);
    gate.complete();

    expect((await first)?.bytes, <int>[4, 5, 6]);
    expect((await second)?.joined, isTrue);
    expect(backend.readAllCalls, 1);
  });

  test('evicts least-recently-used bytes within manager bounds', () async {
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(
      backend: backend,
      memoryMaxEntries: 2,
      memoryMaxBytes: 7,
    );
    final first = _id('first');
    final second = _id('second');
    final third = _id('third');
    manager.remember(id: first, bytes: Uint8List(3));
    manager.remember(id: second, bytes: Uint8List(3));
    expect(manager.lookupMemory(first, length: 3), isNotNull);
    manager.remember(id: third, bytes: Uint8List(4));

    expect(manager.lookupMemory(first, length: 3), isNotNull);
    expect(manager.lookupMemory(second, length: 3), isNull);
    expect(manager.lookupMemory(third, length: 4), isNotNull);
    expect(manager.memoryEntryCount, 2);
    expect(manager.memoryBytes, 7);
  });

  test('rejects changed advertised length without retaining bytes', () async {
    final id = _id('changed');
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List(5),
    });
    final manager = ArtifactCacheManager(backend: backend);
    final lookup = ArtifactCacheLookup(
      id: id,
      entry: ArtifactCacheStreamEntry(
        length: 4,
        open: ({required int start, int? endExclusive}) async* {
          yield Uint8List(5);
        },
        readAll: () async => Uint8List(5),
      ),
      tier: ArtifactCacheTier.persistent,
    );

    await expectLater(manager.readForegroundLookup(lookup), throwsStateError);
    expect(manager.lookupMemory(id), isNull);
  });

  test('purges an empty memory/backend artifact instead of serving it',
      () async {
    final id = _id('empty');
    final backend = _InvalidatingBackend(<DownloadId, Uint8List>{
      id: Uint8List(0),
    });
    final manager = ArtifactCacheManager(backend: backend);
    manager.remember(id: id, bytes: Uint8List(0), durable: true);

    expect(manager.lookupMemory(id), isNull);
    expect(await manager.readForeground(id), isNull);
    expect(backend.invalidated, contains(id));
    expect(backend.values[id], isNull);
  });

  test('refuses to write an empty promoted artifact', () async {
    final id = _id('empty-store');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);

    await expectLater(
      manager.storePromotedArtifact(id: id, bytes: Uint8List(0)),
      throwsStateError,
    );
    expect(backend.values, isEmpty);
  });

  test('writes through the backend and updates the memory tier', () async {
    final id = _id('store');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    final bytes = Uint8List.fromList(<int>[7, 8, 9]);

    await manager.storePromotedArtifact(id: id, bytes: bytes);

    expect(backend.values[id], bytes);
    expect(manager.lookupMemory(id), bytes);
  });

  test('verified version alias reuses a different exact URL artifact', () async {
    final oldId = _versionId('old', 'https://e-hentai.org/g/1/old/001.jpg');
    final newId = _versionId('new', 'https://e-hentai.org/g/2/new/001.jpg');
    final bytes = Uint8List.fromList(<int>[9, 8, 7, 6]);
    final backend = _Backend(<DownloadId, Uint8List>{oldId: bytes});
    final manager = ArtifactCacheManager(backend: backend);

    manager.alias(id: newId, target: oldId);
    final lookup = await manager.lookup(newId);
    final read = await manager.readForeground(newId);

    expect(lookup?.id, newId);
    expect(lookup?.storageId, oldId);
    expect(read?.bytes, bytes);
    expect(backend.openCalls, 1);
    expect(manager.aliasCount, 1);
  });

  test('verified equivalence observes artifacts promoted after registration',
      () async {
    final older = _id('older-equivalent');
    final newer = _id('newer-equivalent');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);

    manager.linkEquivalent(first: older, second: newer);
    expect(manager.equivalenceCount, 1);
    expect(await manager.readForeground(older), isNull);
    expect(await manager.readForeground(newer), isNull);

    await manager.storePromotedArtifact(
      id: newer,
      bytes: Uint8List.fromList(<int>[4, 4, 4]),
    );

    final reused = await manager.lookup(older);
    expect(reused?.id, older);
    expect(reused?.storageId, newer);
    expect((await manager.readForeground(older))?.bytes, <int>[4, 4, 4]);
    expect(manager.resolveAlias(older), older);
    expect(manager.resolveAlias(newer), newer);

    await manager.storePromotedArtifact(
      id: older,
      bytes: Uint8List.fromList(<int>[8, 8, 8]),
    );
    expect((await manager.readForeground(older))?.bytes, <int>[8, 8, 8]);
    expect((await manager.readForeground(newer))?.bytes, <int>[4, 4, 4]);
  });

  test('verified equivalence does not satisfy exact backend ownership',
      () async {
    final older = _id('older-owner');
    final newer = _id('newer-owner');
    final backend = _Backend(<DownloadId, Uint8List>{
      newer: Uint8List.fromList(<int>[3, 3, 3]),
    });
    final manager = ArtifactCacheManager(backend: backend);
    manager.linkEquivalent(first: older, second: newer);

    expect(await manager.contains(id: older, expectedLength: 3), isTrue);
    expect(
      await manager.containsBackend(id: older, expectedLength: 3),
      isFalse,
    );
    expect(await manager.lookupAuthoritative(older), isNull);
    expect(await manager.rekey(oldId: older, newId: _id('migrated')), isFalse);
    expect(backend.values[newer], <int>[3, 3, 3]);
  });

  test('artifact aliases chain, reject cycles and detach on new write', () async {
    final first = _id('first-version');
    final second = _id('second-version');
    final third = _id('third-version');
    final backend = _Backend(<DownloadId, Uint8List>{
      first: Uint8List.fromList(<int>[1, 2, 3]),
    });
    final manager = ArtifactCacheManager(backend: backend);

    manager.alias(id: second, target: first);
    manager.alias(id: third, target: second);
    expect(manager.resolveAlias(third), first);
    expect(
      () => manager.alias(id: first, target: third),
      throwsStateError,
    );

    await manager.storePromotedArtifact(
      id: third,
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
    );
    expect(manager.resolveAlias(third), third);
    expect((await manager.readForeground(third))?.bytes, <int>[4, 5, 6]);
    expect((await manager.readForeground(first))?.bytes, <int>[1, 2, 3]);
  });

  test('invalidating an alias does not delete its authoritative target',
      () async {
    final oldId = _id('old-target');
    final newId = _id('new-alias');
    final backend = _InvalidatingBackend(<DownloadId, Uint8List>{
      oldId: Uint8List.fromList(<int>[3, 2, 1]),
    });
    final manager = ArtifactCacheManager(backend: backend);
    manager.alias(id: newId, target: oldId);

    await manager.invalidate(newId);

    expect(manager.aliasCount, 0);
    expect(backend.invalidated, isNot(contains(oldId)));
    expect((await manager.readForeground(oldId))?.bytes, <int>[3, 2, 1]);
  });

  test('rekey copies authoritative bytes and deletes the old exact key',
      () async {
    final oldId = _id('old-key');
    final newId = _id('new-key');
    final backend = _InvalidatingBackend(<DownloadId, Uint8List>{
      oldId: Uint8List.fromList(<int>[5, 5, 5]),
    });
    final manager = ArtifactCacheManager(backend: backend);

    expect(await manager.rekey(oldId: oldId, newId: newId), isTrue);
    expect(backend.values[oldId], isNull);
    expect(backend.values[newId], <int>[5, 5, 5]);
  });
}

DownloadId _id(String page) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: page,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('memory://$page'),
    );

DownloadId _versionId(String version, String uri) => DownloadId(
      content: ContentId(
        sourceId: 'venera:ehentai',
        comicId: 'gallery-$version',
        chapterId: 'chapter-$version',
        pageId: 'page-0',
      ),
      sourceRevision: version,
      canonicalUri: Uri.parse(uri),
    );

final class _Backend implements ArtifactCacheBackend {
  _Backend(this.values, {this.readGate});

  final Map<DownloadId, Uint8List> values;
  final Completer<void>? readGate;
  int openCalls = 0;
  int readAllCalls = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    openCalls++;
    final bytes = values[id];
    if (bytes == null) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.sublistView(
          bytes,
          start,
          endExclusive ?? bytes.lengthInBytes,
        );
      },
      readAll: () async {
        readAllCalls++;
        await readGate?.future;
        return bytes;
      },
    );
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


final class _InvalidatingBackend extends _Backend
    implements ArtifactCacheBackend {
  _InvalidatingBackend(super.values);

  final List<DownloadId> invalidated = <DownloadId>[];

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    invalidated.add(id);
    values.remove(id);
  }


}
