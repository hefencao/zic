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

  test('sqlite artifact_object locator is independent from logical binding path',
      () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final first = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/shared-old.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 1,
      touchedUs: 1,
      artifactId: 'shared-locator-artifact',
      storageRootId: '/tmp',
    );
    final second = CacheRec(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'locator-successor',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/locator-successor.webp'),
      ),
      state: CacheState.ready,
      path: '/tmp/shared-current.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 2,
      touchedUs: 2,
      artifactId: 'shared-locator-artifact',
      storageRootId: '/tmp',
    );
    await index.put(first);
    await index.put(second);

    expect((await index.get(first.key))!.path, '/tmp/shared-old.bin');
    final object = await index.getArtifactObject('shared-locator-artifact');
    expect(object, isNotNull);
    expect(object!.accessLocator, '/tmp/shared-current.bin');
    expect(object.bytes, 3);
    expect(object.checksum, '01020304');
  });

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
    final legacyObject = await index.getArtifactObject(record.effectiveArtifactId);
    expect(legacyObject, isNotNull);
    expect(legacyObject!.accessLocator, record.path);
    expect(legacyObject.storageRootId, record.storageRootId);

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
  test('memory export page bindings enforce the same sparse ordinal contract',
      () async {
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    const first = ExportPageBinding(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page-a',
      logicalIndex: 2,
      exportOrdinal: 3,
    );
    await index.putExportPageBindings(const <ExportPageBinding>[first]);
    expect(
      await index.listExportPageBindings(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
      ),
      const <ExportPageBinding>[first],
    );
    await expectLater(
      index.putExportPageBindings(
        const <ExportPageBinding>[
          ExportPageBinding(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: 'page-a',
            logicalIndex: 4,
            exportOrdinal: 9,
          ),
        ],
      ),
      throwsStateError,
    );
  });

  test('sqlite export page bindings persist sparse immutable ordinals', () async {
    final directory = await Directory.systemTemp.createTemp('export-binding-');
    addTearDown(() => directory.delete(recursive: true));
    final dbPath = '${directory.path}/export-binding.sqlite';
    final index = SqliteIndex(dbPath);
    await index.open();
    final bindings = <ExportPageBinding>[
      const ExportPageBinding(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'old-a',
        logicalIndex: 2,
        exportOrdinal: 3,
        placementGeneration: 4,
      ),
      const ExportPageBinding(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'old-b',
        logicalIndex: 3,
        exportOrdinal: 2,
        placementGeneration: 4,
      ),
    ];
    await index.putExportPageBindings(bindings);
    await index.close();

    final reopened = SqliteIndex(dbPath);
    await reopened.open();
    addTearDown(reopened.close);
    final restored = await reopened.listExportPageBindings(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
    );
    expect(restored, <ExportPageBinding>[bindings[1], bindings[0]]);

    await reopened.putExportPageBindings(<ExportPageBinding>[
      const ExportPageBinding(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'old-a',
        logicalIndex: 4,
        exportOrdinal: 3,
        placementGeneration: 5,
      ),
    ]);
    expect(
      (await reopened.listExportPageBindings(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
      ))
          .singleWhere((binding) => binding.pageId == 'old-a')
          .logicalIndex,
      4,
    );

    await expectLater(
      reopened.putExportPageBindings(<ExportPageBinding>[
        const ExportPageBinding(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'old-a',
          logicalIndex: 4,
          exportOrdinal: 7,
        ),
      ]),
      throwsStateError,
    );
  });

  test('v6 cache metadata migrates existing root identities into schema 7', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_v6_root_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    const rootIdentity = '/storage/emulated/0/Books';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'v6-root',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v6-root.webp'),
    );

    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '$rootIdentity/final/page.bin',
        bytes: 3,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        storageRootId: rootIdentity,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('DROP TABLE storage_access_locator');
    legacy.execute('DROP TABLE storage_root');
    legacy.execute('PRAGMA user_version = 6');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    addTearDown(migrated.close);
    final root = await migrated.getStorageRoot(rootIdentity);
    expect(root, isNotNull);
    expect(root!.rootId, rootIdentity);
    expect(root.accessLocators, hasLength(1));
    expect(root.accessLocators.single.kind, StorageAccessLocatorKind.direct);
    expect(root.accessLocators.single.locator, rootIdentity);
    expect(root.accessLocators.single.health, StorageAccessHealth.unknown);
  });

  test('v7 cache metadata backfills the compatibility object as replica one', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_v7_replica_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'v7-replica',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v7-replica.webp'),
    );
    const root = '/storage/emulated/0/Books';
    const artifactId = 'v7-artifact';
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '$root/final/page.bin',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        artifactId: artifactId,
        storageRootId: root,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('DROP TABLE artifact_replica');
    legacy.execute('PRAGMA user_version = 7');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    addTearDown(migrated.close);
    final replicas = await migrated.listArtifactReplicas(artifactId);
    expect(replicas, hasLength(1));
    expect(replicas.single.replicaId, artifactId);
    expect(replicas.single.accessLocator, '$root/final/page.bin');
    expect(replicas.single.storageRootId, root);
  });

  test('v8 cache metadata adds durable replica migration state through schema 11', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_v8_migration_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'v8-migration',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v8-migration.webp'),
    );
    const artifactId = 'v8-migration-artifact';
    const sourceRoot = '/storage/source';
    const sourcePath = '/storage/source/page.bin';
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: sourcePath,
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        artifactId: artifactId,
        storageRootId: sourceRoot,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('DROP TABLE artifact_replica_migration');
    legacy.execute('PRAGMA user_version = 8');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    final replica = (await migrated.listArtifactReplicas(artifactId)).single;
    expect(replica.replicaId, artifactId);
    final started = await migrated.beginArtifactReplicaMigration(
      replicaId: replica.replicaId,
      sourceAccessLocator: sourcePath,
      sourceStorageRootId: sourceRoot,
      destinationAccessLocator: '/storage/destination/page.bin',
      destinationStorageRootId: '/storage/destination',
      temporaryAccessLocator: '/storage/destination/page.bin.part',
      touchedUs: 3,
    );
    expect(started.phase, ArtifactReplicaMigrationPhase.copying);
    await migrated.close();

    final schema = sql.sqlite3.open(dbPath);
    expect(schema.select('PRAGMA user_version').single.values.single, 11);
    expect(
      schema
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'artifact_replica_migration'",
          )
          .length,
      1,
    );
    schema.dispose();
  });

  test('v10 migration clears cache-final and partial legacy pins only', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_v10_pin_migration_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    DownloadId id(String pageId) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'retention-migration',
            chapterId: 'chapter',
            pageId: pageId,
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/$pageId.webp'),
        );
    final cacheFinal = id('cache-final');
    final partial = id('partial');
    final structuredPinned = id('structured-pinned');
    final structuredUnpinned = id('structured-unpinned');
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: cacheFinal,
        state: CacheState.ready,
        path: '${temp.path}/final/cache-final.webp',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
        pinned: true,
      ),
    );
    await current.put(
      CacheRec(
        id: partial,
        state: CacheState.partial,
        path: '${temp.path}/partial/partial.part',
        bytes: 2,
        checksum: '',
        createdUs: 1,
        touchedUs: 1,
        pinned: true,
      ),
    );
    await current.put(
      CacheRec(
        id: structuredPinned,
        state: CacheState.ready,
        path: '${temp.path}/Manual Comic/001.webp',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
        pinned: true,
      ),
    );
    await current.put(
      CacheRec(
        id: structuredUnpinned,
        state: CacheState.ready,
        path: '${temp.path}/Manual Comic/002.webp',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('PRAGMA user_version = 10');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    addTearDown(migrated.close);

    expect((await migrated.get(cacheFinal.key))!.pinned, isFalse);
    expect((await migrated.get(partial.key))!.pinned, isFalse);
    expect((await migrated.get(structuredPinned.key))!.pinned, isTrue);
    expect((await migrated.get(structuredUnpinned.key))!.pinned, isFalse,
        reason: 'migration must not invent manual intent for ambiguous old rows');
    final raw = sql.sqlite3.open(dbPath);
    expect(raw.select('PRAGMA user_version').single.values.single, 11);
    raw.dispose();
  });

  test('current cache schema does not rerun legacy identity migration on reopen',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'cache_index_current_reopen_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.close();

    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source/legacy',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/current-reopen.webp'),
    );
    final raw = sql.sqlite3.open(dbPath);
    expect(raw.select('PRAGMA user_version').single.values.single, 11);
    raw.execute(
      'INSERT INTO cache_entry '
      '(key, download_json, state, path, bytes, checksum, created_us, touched_us, '
      'pinned, checksum_algorithm, artifact_id, storage_root_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id.legacyKey,
        jsonEncode(id.toJson()),
        CacheState.partial.name,
        '${temp.path}/legacy.part',
        1,
        '',
        1,
        1,
        0,
        'crc32',
        '',
        'default',
      ],
    );
    raw.dispose();

    final reopened = SqliteIndex(dbPath);
    await reopened.open();
    addTearDown(reopened.close);
    expect(await reopened.get(id.legacyKey), isNotNull);
    expect(
      await reopened.get(id.key),
      isNull,
      reason: 'schema-11 reopen must not rescan/rewrite all cache identities',
    );
  });

  test('replica migration authority switch and cleanup debt survive reopen', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_migration_state_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'migration-state',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/migration-state.webp'),
    );
    const artifactId = 'migration-state-artifact';
    const sourceRoot = '/storage/a';
    const sourcePath = '/storage/a/page.bin';
    const destinationRoot = '/storage/b';
    const destinationPath = '/storage/b/page.bin';
    const temporaryPath = '/storage/b/page.bin.part';
    final first = SqliteIndex(dbPath);
    await first.open();
    await first.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: sourcePath,
        bytes: 4,
        checksum: '01020304',
        createdUs: 10,
        touchedUs: 20,
        artifactId: artifactId,
        storageRootId: sourceRoot,
      ),
    );
    final replica = (await first.listArtifactReplicas(artifactId)).single;
    await first.beginArtifactReplicaMigration(
      replicaId: replica.replicaId,
      sourceAccessLocator: sourcePath,
      sourceStorageRootId: sourceRoot,
      destinationAccessLocator: destinationPath,
      destinationStorageRootId: destinationRoot,
      temporaryAccessLocator: temporaryPath,
      touchedUs: 30,
    );
    expect(
      (await first.listArtifactReplicas(artifactId)).single.accessLocator,
      sourcePath,
      reason: 'copying progress must not become replica authority',
    );
    await first.close();

    final second = SqliteIndex(dbPath);
    await second.open();
    final restored = await second.getArtifactReplicaMigration(replica.replicaId);
    expect(restored, isNotNull);
    expect(restored!.phase, ArtifactReplicaMigrationPhase.copying);
    expect(restored.temporaryAccessLocator, temporaryPath);
    final moved = await second.commitArtifactReplicaMigration(
      replicaId: replica.replicaId,
      touchedUs: 40,
    );
    expect(moved.replicaId, replica.replicaId);
    expect(moved.accessLocator, destinationPath);
    expect((await second.get(id.key))!.path, destinationPath);
    expect(
      (await second.get(id.key))!.touchedUs,
      20,
      reason: 'physical relocation must not refresh logical cache recency',
    );
    expect(
      (await second.getArtifactReplicaMigration(replica.replicaId))!.phase,
      ArtifactReplicaMigrationPhase.cleanupPending,
    );
    await second.close();

    final third = SqliteIndex(dbPath);
    await third.open();
    expect(
      (await third.getArtifactReplicaMigration(replica.replicaId))!.phase,
      ArtifactReplicaMigrationPhase.cleanupPending,
    );
    expect(
      (await third.listArtifactReplicas(artifactId)).single.accessLocator,
      destinationPath,
    );
    await third.finishArtifactReplicaMigrationCleanup(replica.replicaId);
    expect(await third.getArtifactReplicaMigration(replica.replicaId), isNull);
    await third.close();
  });

  test('mutable partial records never become immutable artifact replicas', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'partial-no-replica',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/partial-no-replica.webp'),
    );
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.partial,
        path: '/storage/a/partial/page.part',
        bytes: 4,
        checksum: '00000000',
        createdUs: 1,
        touchedUs: 1,
        artifactId: 'partial-object',
        storageRootId: '/storage/a',
      ),
    );
    expect(await index.listArtifactReplicas('partial-object'), isEmpty);
  });

  test('one artifact keeps independent replicas on two physical roots', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final firstId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'replica-a',
        chapterId: 'chapter',
        pageId: 'page-a',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/replica-a.webp'),
    );
    final secondId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'replica-b',
        chapterId: 'chapter',
        pageId: 'page-b',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/replica-b.webp'),
    );
    const artifactId = 'multi-root-artifact';
    const rootA = '/storage/a';
    const rootB = '/storage/b';
    await index.put(
      CacheRec(
        id: firstId,
        state: CacheState.ready,
        path: '$rootA/final/page.bin',
        bytes: 8,
        checksum: '11112222',
        createdUs: 1,
        touchedUs: 1,
        artifactId: artifactId,
        storageRootId: rootA,
      ),
    );
    await index.putArtifactReplica(
      artifactId: artifactId,
      accessLocator: '$rootB/final/page.bin',
      storageRootId: rootB,
      createdUs: 2,
      touchedUs: 2,
    );

    final replicas = await index.listArtifactReplicas(artifactId);
    expect(replicas, hasLength(2));
    expect(
      replicas.map((value) => value.accessLocator).toSet(),
      <String>{'$rootA/final/page.bin', '$rootB/final/page.bin'},
    );
    expect(replicas.map((value) => value.replicaId).toSet(), hasLength(2));
    expect(replicas.any((value) => value.replicaId == artifactId), isTrue);
    expect((await index.getArtifactObject(artifactId))?.accessLocator,
        '$rootA/final/page.bin',
        reason: 'adding a replica must not silently move the compatibility object');

    await index.put(
      CacheRec(
        id: secondId,
        state: CacheState.ready,
        path: '$rootB/final/relocated.bin',
        bytes: 8,
        checksum: '11112222',
        createdUs: 3,
        touchedUs: 3,
        artifactId: artifactId,
        storageRootId: rootB,
      ),
    );
    final afterBindingWrite = await index.listArtifactReplicas(artifactId);
    expect(afterBindingWrite, hasLength(2),
        reason: 'ordinary binding/object updates are not implicit replica copies');
  });

  test('schema 7 backfills one durable locator for a storage root', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final rootId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'root-backfill',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/root-backfill.webp'),
    );
    await index.put(
      CacheRec(
        id: rootId,
        state: CacheState.ready,
        path: '/storage/emulated/0/Books/final/page.bin',
        bytes: 3,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        storageRootId: '/storage/emulated/0/Books',
      ),
    );

    final root = await index.getStorageRoot('/storage/emulated/0/Books');
    expect(root, isNotNull);
    expect(root!.accessLocators, hasLength(1));
    expect(root.accessLocators.single.kind, StorageAccessLocatorKind.direct);
    expect(root.accessLocators.single.health, StorageAccessHealth.unknown);
  });

  test('verified SAF and Direct locators merge into one durable root', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    const direct = '/storage/emulated/0/Books';
    const saf =
        'content://com.android.externalstorage.documents/tree/primary%3ABooks';
    final directId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'root-direct',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/direct.webp'),
    );
    final safId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'root-saf',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/saf.webp'),
    );
    await index.put(
      CacheRec(
        id: directId,
        state: CacheState.ready,
        path: '$direct/final/direct.bin',
        bytes: 3,
        checksum: '11111111',
        createdUs: 1,
        touchedUs: 1,
        storageRootId: direct,
      ),
    );
    await index.put(
      CacheRec(
        id: safId,
        state: CacheState.ready,
        path: 'saf:placeholder',
        bytes: 3,
        checksum: '22222222',
        createdUs: 2,
        touchedUs: 2,
        storageRootId: saf,
      ),
    );

    final merged = await index.registerStorageRootAccessAliasProof(
      const StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(direct),
        saf: SafStorageAccessLocator(saf),
      ),
      verifiedUs: 99,
    );

    expect(merged.accessLocators, hasLength(2));
    expect(
      merged.accessLocators.map((value) => value.kind).toSet(),
      <StorageAccessLocatorKind>{
        StorageAccessLocatorKind.direct,
        StorageAccessLocatorKind.saf,
      },
    );
    expect(
      merged.accessLocators.every(
        (value) => value.health == StorageAccessHealth.healthy &&
            value.verifiedUs == 99,
      ),
      isTrue,
    );
    expect((await index.getStorageRoot(direct))?.rootId, merged.rootId);
    expect((await index.getStorageRoot(saf))?.rootId, merged.rootId);
    final directRecord = await index.get(directId.key);
    final safRecord = await index.get(safId.key);
    final directReplica = (
      await index.listArtifactReplicas(directRecord!.effectiveArtifactId)
    ).single;
    final safReplica = (
      await index.listArtifactReplicas(safRecord!.effectiveArtifactId)
    ).single;
    expect(directReplica.storageRootId, merged.rootId);
    expect(safReplica.storageRootId, merged.rootId);
  });

  test('storage-root alias merge keeps durable migration roots aligned', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    const direct = '/storage/emulated/0/MigrationBooks';
    const saf =
        'content://com.android.externalstorage.documents/tree/primary%3AMigrationBooks';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'migration-root-merge',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/migration-root-merge.webp'),
    );
    const artifactId = 'migration-root-merge-artifact';
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '$direct/final/page.bin',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
        artifactId: artifactId,
        storageRootId: direct,
      ),
    );
    final replica = (await index.listArtifactReplicas(artifactId)).single;
    await index.beginArtifactReplicaMigration(
      replicaId: replica.replicaId,
      sourceAccessLocator: replica.accessLocator,
      sourceStorageRootId: direct,
      destinationAccessLocator: 'saf:destination',
      destinationStorageRootId: saf,
      temporaryAccessLocator: 'saf:temporary',
      touchedUs: 2,
    );

    final merged = await index.registerStorageRootAccessAliasProof(
      const StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(direct),
        saf: SafStorageAccessLocator(saf),
      ),
      verifiedUs: 3,
    );

    final afterReplica = (await index.listArtifactReplicas(artifactId)).single;
    final migration = await index.getArtifactReplicaMigration(replica.replicaId);
    expect(afterReplica.storageRootId, merged.rootId);
    expect(migration, isNotNull);
    expect(migration!.sourceStorageRootId, merged.rootId);
    expect(migration.destinationStorageRootId, merged.rootId);
    expect(migration.phase, ArtifactReplicaMigrationPhase.copying);
  });

  test('access health changes do not alter root identity', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    const direct = '/storage/emulated/0/Books';
    const saf =
        'content://com.android.externalstorage.documents/tree/primary%3ABooks';
    final root = await index.registerStorageRootAccessAliasProof(
      const StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(direct),
        saf: SafStorageAccessLocator(saf),
      ),
      verifiedUs: 10,
    );

    await index.updateStorageAccessHealth(
      kind: StorageAccessLocatorKind.direct,
      locator: direct,
      health: StorageAccessHealth.accessDenied,
      touchedUs: 11,
    );

    final current = await index.getStorageRoot(root.rootId);
    expect(current, isNotNull);
    final directAccess = current!.accessLocators.singleWhere(
      (value) => value.kind == StorageAccessLocatorKind.direct,
    );
    final safAccess = current.accessLocators.singleWhere(
      (value) => value.kind == StorageAccessLocatorKind.saf,
    );
    expect(directAccess.health, StorageAccessHealth.accessDenied);
    expect(safAccess.health, StorageAccessHealth.healthy);
    expect(current.rootId, root.rootId);
  });

  test('DownloadPlacement equality includes export page order', () {
    final now = DateTime.utc(2026, 9, 6);
    final origin = DownloadPlacement(
      placementId: 'p',
      sourceId: 'source',
      comicId: 'comic',
      comicTitle: 'title',
      mode: DownloadPlacementMode.incremental,
      relativeDirectory: 'dir',
      pageOrder: ComicPageOrder.origin,
      createdAt: now,
      updatedAt: now,
    );
    expect(
      origin,
      isNot(origin.copyWith(pageOrder: ComicPageOrder.chronological)),
    );
  });

}
