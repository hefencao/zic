import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('writeComicFolderManifest persists pageOrder into .zic.json', () async {
    final root = await Directory.systemTemp.createTemp('zic-manifest-pageorder-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'lib:ch1',
        displayName: '第一话',
        sourceId: 'src1',
        comicId: 'comic1',
        comicTitle: '逆序漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 100,
          ),
        ],
      ),
    );

    await service.claimComicDirectory(
      sourceId: 'src1',
      comicId: 'comic1',
      comicTitle: '逆序漫画',
      directoryName: '逆序漫画',
      pageOrder: ComicPageOrder.chronological,
    );

    await service.artifactStore.writeComicFolderManifest(entry);
    final manifestFile = File(
      '${service.artifactStore.layout.root}/逆序漫画/$comicManifestFileName',
    );
    expect(await manifestFile.exists(), isTrue);
    final manifest = ComicFolderManifest.decode(await manifestFile.readAsString());
    expect(manifest, isNotNull);
    expect(manifest!.pageOrder, ComicPageOrder.chronological);
  });

  test('persisted placement resolve is generation-stable when binding is unchanged',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-placement-generation-');
    addTearDown(() => root.delete(recursive: true));
    final first = await PersistentChapterDownloadService.open(root.path);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'lib:ch1',
        displayName: '第一话',
        sourceId: 'source',
        comicId: 'comic',
        comicTitle: '漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );
    await first.claimComicDirectory(
      sourceId: 'source',
      comicId: 'comic',
      comicTitle: '漫画',
      directoryName: '漫画',
      pageOrder: ComicPageOrder.origin,
    );
    final initial = await first.artifactStore.index.getPlacement(
      sourceId: 'source',
      comicId: 'comic',
    );
    expect(initial, isNotNull);
    await first.close();

    final reopened = await PersistentChapterDownloadService.open(root.path);
    addTearDown(reopened.close);
    final once = await reopened.artifactStore.resolveDownloadPlacement(entry);
    final twice = await reopened.artifactStore.resolveDownloadPlacement(entry);
    final durable = await reopened.artifactStore.index.getPlacement(
      sourceId: 'source',
      comicId: 'comic',
    );
    expect(once.generation, initial!.generation);
    expect(twice.generation, initial.generation);
    expect(durable?.generation, initial.generation);
  });

  test('auto export order requires verified single-chapter front-prepend evidence',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-pageorder-auto-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    ImportedLibraryEntry entry(String comicId, int pageCount) =>
        ImportedLibraryEntry(
          chapter: ImportedChapterRecord(
            directoryId: 'lib:$comicId',
            displayName: '第一话',
            sourceId: 'venera:ehentai',
            comicId: comicId,
            comicTitle: comicId,
            chapterId: 'ch1',
            sourceRevision: 'r1',
            pages: List<ImportedPageRecord>.generate(
              pageCount,
              (index) => ImportedPageRecord(
                displayName: '${index + 1}.webp',
                sourceId: 'https://example.test/$comicId/$index.webp',
                pageId: 'p$index',
                contentKindHint: ContentKindHint.webp,
              ),
            ),
          ),
        );

    final unrelated = entry('unrelated', 3);
    final unrelatedPlacement =
        await service.artifactStore.resolveDownloadPlacement(unrelated);
    final unrelatedFrozen = await service.artifactStore.freezeExportPageOrder(
      unrelated,
      unrelatedPlacement,
      isSingleChapter: true,
    );
    expect(unrelatedFrozen.pageOrder, ComicPageOrder.origin);

    service.updateVersionBaselines(<ComicVersionRelation>[
      const ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'old',
        successorComicId: 'new',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'ch1',
            successorChapterId: 'ch1',
            predecessorPageCount: 3,
            successorPageCount: 5,
            successorOffset: 2,
          ),
        ],
      ),
    ]);
    final successor = entry('new', 5);
    final successorPlacement =
        await service.artifactStore.resolveDownloadPlacement(successor);
    final successorFrozen = await service.artifactStore.freezeExportPageOrder(
      successor,
      successorPlacement,
      isSingleChapter: true,
    );
    expect(successorFrozen.pageOrder, ComicPageOrder.chronological);

    final predecessor = entry('old', 3);
    final predecessorPlacement =
        await service.artifactStore.resolveDownloadPlacement(predecessor);
    final multiChapterFrozen = await service.artifactStore.freezeExportPageOrder(
      predecessor,
      predecessorPlacement,
      isSingleChapter: false,
    );
    expect(multiChapterFrozen.pageOrder, ComicPageOrder.origin);
  });

  test('chronological export ordinals survive front-prepend without N-index recompute',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-export-ordinal-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    ImportedLibraryEntry entry(String revision, List<String> pageIds) =>
        ImportedLibraryEntry(
          chapter: ImportedChapterRecord(
            directoryId: 'lib:$revision',
            displayName: '第一话',
            sourceId: 'source',
            comicId: 'comic',
            comicTitle: '漫画',
            chapterId: 'ch1',
            sourceRevision: revision,
            pages: <ImportedPageRecord>[
              for (final pageId in pageIds)
                ImportedPageRecord(
                  displayName: '$pageId.webp',
                  sourceId: 'https://example.test/$revision/$pageId.webp',
                  pageId: pageId,
                  contentKindHint: ContentKindHint.webp,
                ),
            ],
          ),
        );

    final first = entry('r1', <String>['a', 'b', 'c']);
    await service.claimComicDirectory(
      sourceId: 'source',
      comicId: 'comic',
      comicTitle: '漫画',
      directoryName: '漫画',
      pageOrder: ComicPageOrder.chronological,
    );
    final placement = await service.artifactStore.resolveDownloadPlacement(first);
    final initial =
        await service.artifactStore.ensureExportPageOrdinals(first, placement);
    expect(initial, <String, int>{'a': 3, 'b': 2, 'c': 1});

    final prepended = entry('r2', <String>['x', 'y', 'a', 'b', 'c']);
    final afterPrepend = await service.artifactStore.ensureExportPageOrdinals(
      prepended,
      placement,
    );
    expect(
      afterPrepend,
      <String, int>{'x': 5, 'y': 4, 'a': 3, 'b': 2, 'c': 1},
    );

    final bindings = await service.artifactStore.index.listExportPageBindings(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'ch1',
    );
    expect(bindings, hasLength(5));
    expect(
      bindings.singleWhere((binding) => binding.pageId == 'a').exportOrdinal,
      3,
    );
    expect(
      bindings.singleWhere((binding) => binding.pageId == 'a').logicalIndex,
      2,
    );

    final middleInsert = entry('r3', <String>['x', 'a', 'y', 'b', 'c']);
    await expectLater(
      service.artifactStore.ensureExportPageOrdinals(middleInsert, placement),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.policy,
        ),
      ),
    );
  });

  test('chronological ordinals inherit across sparse version chain only from materialized anchor',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-version-ordinal-anchor-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    ImportedLibraryEntry entry(String comicId, int pageCount) =>
        ImportedLibraryEntry(
          chapter: ImportedChapterRecord(
            directoryId: 'lib:$comicId',
            displayName: '第一话',
            sourceId: 'source',
            comicId: comicId,
            comicTitle: comicId,
            chapterId: 'ch1',
            sourceRevision: 'r1',
            pages: List<ImportedPageRecord>.generate(
              pageCount,
              (index) => ImportedPageRecord(
                displayName: '${index + 1}.webp',
                sourceId: 'https://example.test/$comicId/$index.webp',
                pageId: '$comicId-p$index',
                contentKindHint: ContentKindHint.webp,
              ),
            ),
          ),
        );

    final baselines = resolveComicVersionBaselines(
      relations: const <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 'source',
          predecessorComicId: 'old',
          successorComicId: 'middle',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'ch1',
              successorChapterId: 'ch1',
              predecessorPageCount: 3,
              successorPageCount: 5,
              successorOffset: 2,
            ),
          ],
        ),
        ComicVersionRelation(
          sourceId: 'source',
          predecessorComicId: 'middle',
          successorComicId: 'new',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'ch1',
              successorChapterId: 'ch1',
              predecessorPageCount: 5,
              successorPageCount: 6,
              successorOffset: 1,
            ),
          ],
        ),
      ],
      manualDownloadComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 'source', comicId: 'old'),
        ComicVersionIdentity(sourceId: 'source', comicId: 'new'),
      ],
    );
    expect(baselines.downloadHeadRelations, hasLength(2));
    final oldToHead = baselines.downloadHeadRelations.singleWhere(
      (relation) => relation.predecessorComicId == 'old',
    );
    expect(oldToHead.successorComicId, 'new');
    expect(oldToHead.pageMappings.single.successorOffset, 3);
    service.updateVersionBaselines(baselines.downloadHeadRelations);

    final old = entry('old', 3);
    await service.claimComicDirectory(
      sourceId: 'source',
      comicId: 'old',
      comicTitle: 'old',
      directoryName: 'old',
      pageOrder: ComicPageOrder.chronological,
    );
    final oldPlacement = await service.artifactStore.resolveDownloadPlacement(old);
    expect(
      await service.artifactStore.ensureExportPageOrdinals(old, oldPlacement),
      <String, int>{'old-p0': 3, 'old-p1': 2, 'old-p2': 1},
    );

    expect(
      await service.artifactStore.index.listExportPageBindings(
        sourceId: 'source',
        comicId: 'middle',
        chapterId: 'ch1',
      ),
      isEmpty,
      reason: 'unopened intermediate versions stay sparse',
    );

    final newest = entry('new', 6);
    await service.claimComicDirectory(
      sourceId: 'source',
      comicId: 'new',
      comicTitle: 'new',
      directoryName: 'new',
      pageOrder: ComicPageOrder.chronological,
    );
    final newPlacement = await service.artifactStore.resolveDownloadPlacement(newest);
    expect(
      await service.artifactStore.ensureExportPageOrdinals(newest, newPlacement),
      <String, int>{
        'new-p0': 6,
        'new-p1': 5,
        'new-p2': 4,
        'new-p3': 3,
        'new-p4': 2,
        'new-p5': 1,
      },
    );
    expect(
      await service.artifactStore.index.listExportPageBindings(
        sourceId: 'source',
        comicId: 'middle',
        chapterId: 'ch1',
      ),
      isEmpty,
      reason: 'graph traversal must not materialize intermediate bindings',
    );
  });

}
