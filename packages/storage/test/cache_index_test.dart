import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  runCacheSchemaV2Tests();

  final id = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page',
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/page.webp'),
  );

  for (final fixture in <String, CacheIndex Function()>{
    'memory': MemIndex.new,
    'sqlite': SqliteIndex.memory,
  }.entries) {
    test('${fixture.key} index upserts and totals records', () async {
      final index = fixture.value();
      await index.open();
      addTearDown(index.close);

      final partial = CacheRec(
        id: id,
        state: CacheState.partial,
        path: '/tmp/page.part',
        bytes: 10,
        checksum: 'a',
        createdUs: 1,
        touchedUs: 2,
      );
      await index.put(partial);
      expect((await index.get(id.key))?.state, CacheState.partial);
      expect(await index.totalBytes(), 10);

      await index.put(
        partial.copyWith(
          state: CacheState.ready,
          path: '/tmp/page.bin',
          bytes: 20,
          checksum: 'b',
          touchedUs: 3,
        ),
      );
      expect(await index.list(state: CacheState.partial), isEmpty);
      expect(await index.totalBytes(state: CacheState.ready), 20);

      await index.remove(id.key);
      expect(await index.get(id.key), isNull);

      final placement = DownloadPlacement(
        placementId: 'source\u0000comic',
        sourceId: 'source',
        comicId: 'comic',
        comicTitle: '漫画测试',
        mode: DownloadPlacementMode.createNew,
        relativeDirectory: '漫画测试',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      await index.putPlacement(placement);
      final retrieved = await index.getPlacement(sourceId: 'source', comicId: 'comic');
      expect(retrieved, isNotNull);
      expect(retrieved!.relativeDirectory, '漫画测试');
      expect(retrieved.mode, DownloadPlacementMode.createNew);
      expect(await index.listPlacements(), hasLength(1));
      await expectLater(
        index.putPlacement(placement.copyWith(relativeDirectory: '另一个目录')),
        throwsA(isA<StateError>()),
      );
      expect(
        (await index.getPlacement(sourceId: 'source', comicId: 'comic'))
            ?.relativeDirectory,
        '漫画测试',
      );

      final committedPlacement = placement.copyWith(
        generation: 1,
        fingerprint: 'fingerprint-a',
      );
      await index.putPlacement(committedPlacement);
      await expectLater(
        index.putPlacement(
          committedPlacement.copyWith(
            fingerprint: 'fingerprint-b',
            updatedAt: DateTime.now().toUtc().add(const Duration(days: 1)),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await index.getPlacement(sourceId: 'source', comicId: 'comic'))
            ?.fingerprint,
        'fingerprint-a',
      );

      await index.putPlacement(
        committedPlacement.copyWith(
          placementId: 'source\u0000comic-v2',
          generation: 2,
          fingerprint: 'fingerprint-c',
        ),
      );
      final replacedPlacement =
          await index.getPlacement(sourceId: 'source', comicId: 'comic');
      expect(replacedPlacement?.placementId, 'source\u0000comic-v2');
      expect(replacedPlacement?.generation, 2);
      expect(await index.listPlacements(), hasLength(1));

      await index.removePlacement(sourceId: 'source', comicId: 'comic');
      expect(await index.getPlacement(sourceId: 'source', comicId: 'comic'), isNull);
    });

    test('${fixture.key} index separates identities that shared a legacy key', () async {
      final first = DownloadId(
        content: const ContentId(
          sourceId: 'source/a',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/page'),
      );
      final second = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'a/comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/page'),
      );
      expect(first.legacyKey, second.legacyKey);
      expect(first.key, isNot(second.key));

      final index = fixture.value();
      await index.open();
      addTearDown(index.close);
      await index.put(
        CacheRec(
          id: first,
          state: CacheState.partial,
          path: '/tmp/first.part',
          bytes: 1,
          checksum: '00000001',
          createdUs: 1,
          touchedUs: 1,
        ),
      );
      await index.put(
        CacheRec(
          id: second,
          state: CacheState.partial,
          path: '/tmp/second.part',
          bytes: 2,
          checksum: '00000002',
          createdUs: 2,
          touchedUs: 2,
        ),
      );

      expect((await index.get(first.key))?.path, '/tmp/first.part');
      expect((await index.get(second.key))?.path, '/tmp/second.part');
      expect(await index.list(), hasLength(2));
    });
  }

  test('sqlite rejects conflicting ready bindings for one artifact identity', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final first = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/shared-a.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 1,
      touchedUs: 1,
      artifactId: 'shared-artifact',
    );
    final second = CacheRec(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'other-page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/other.webp'),
      ),
      state: CacheState.ready,
      path: '/tmp/shared-b.bin',
      bytes: 4,
      checksum: '05060708',
      createdUs: 2,
      touchedUs: 2,
      artifactId: 'shared-artifact',
    );
    await index.put(first);
    await expectLater(index.put(second), throwsA(isA<StateError>()));
    expect((await index.get(first.key))?.checksum, '01020304');
    expect(await index.get(second.key), isNull);
  });
}
void runCacheSchemaV2Tests() {
  test('v1 cache databases migrate to v2 and keep records readable', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_v2_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath =
        '${temp.path}${Platform.pathSeparator}cache.sqlite';

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('PRAGMA user_version = 1');
    legacy.execute('''
      CREATE TABLE cache_entry (
        key TEXT NOT NULL PRIMARY KEY,
        download_json TEXT NOT NULL,
        state TEXT NOT NULL,
        path TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        checksum TEXT NOT NULL,
        created_us INTEGER NOT NULL,
        touched_us INTEGER NOT NULL
      )
    ''');
    final id = DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'legacy',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/legacy.webp'),
    );
    legacy.execute(
      'INSERT INTO cache_entry '
      '(key, download_json, state, path, bytes, checksum, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id.legacyKey,
        jsonEncode(id.toJson()),
        'ready',
        '${temp.path}/final/legacy.bin',
        123,
        'checksum',
        1,
        2,
      ],
    );
    legacy.dispose();

    final index = SqliteIndex(dbPath);
    await index.open();
    addTearDown(index.close);
    final record = await index.get(id.key);
    expect(record, isNotNull);
    expect(record!.pinned, isFalse);

    final pinnedId = DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'pinned',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/pinned.webp'),
    );
    await index.put(
      CacheRec(
        id: pinnedId,
        state: CacheState.ready,
        path: '${temp.path}/final/pinned.bin',
        bytes: 10,
        checksum: 'c',
        createdUs: 3,
        touchedUs: 4,
        pinned: true,
      ),
    );
    expect((await index.get(pinnedId.key))!.pinned, isTrue);
    expect(await index.totalBytes(), 133);

    final placement = DownloadPlacement(
      placementId: 'p-order',
      sourceId: 'source',
      comicId: 'comic',
      comicTitle: 'title',
      mode: DownloadPlacementMode.incremental,
      relativeDirectory: 'dir',
      pageOrder: ComicPageOrder.chronological,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await index.putPlacement(placement);
    final read = await index.getPlacement(sourceId: 'source', comicId: 'comic');
    expect(read?.pageOrder, ComicPageOrder.chronological);
  });
}
