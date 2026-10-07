import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storage/storage.dart';
import 'package:zic/app.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/home_shell.dart';

const _sourceId = 'details-hydration-fixture';
const _comicId = 'stored-comic';
const _chapterId = 'stored-chapter';
const _comic = Comic(
  sourceId: _sourceId,
  comicId: _comicId,
  title: 'Stored details comic',
  authors: <String>[],
  readingDirection: ReadingDirection.ltr,
);

Chapter _chapter({String revision = 'r1', int pageCount = 2}) => Chapter(
      chapterId: _chapterId,
      comicId: _comicId,
      title: 'Stored chapter',
      sequence: 1,
      pageCount: pageCount,
      sourceRevision: revision,
    );

ChapterManifest _manifest(Chapter chapter) => ChapterManifest(
      sourceId: _sourceId,
      comicId: _comicId,
      chapter: chapter,
      readingDirection: ReadingDirection.ltr,
      pages: <PageAsset>[
        for (var i = 0; i < (chapter.pageCount > 0 ? chapter.pageCount : 2); i++)
          PageAsset(
            pageId: 'page-$i', chapterId: _chapterId, index: i,
            uri: Uri.parse('https://example.invalid/page-$i.jpg'),
            contentKindHint: ContentKindHint.jpeg,
          ),
      ],
    );

final class _DetailsSource implements BrowsableComicSource {
  _DetailsSource(this.chapter);

  final Chapter chapter;
  int chapterLoads = 0;

  @override
  String get sourceId => _sourceId;

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId, name: 'Details hydration fixture', language: 'all',
        website: Uri.https('example.invalid', '/'),
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '', int offset = 0, int limit = 24,
  }) async => SourceBrowsePage(items: const [], offset: offset, hasMore: false);

  @override
  Future<ComicManifest> loadComic(String comicId) async => ComicManifest(
        comic: _comic, chapters: <Chapter>[chapter],
      );

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    chapterLoads++;
    return _manifest(chapter);
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
}

// Use the production snapshot codec for Home's read-only list projection;
// targeted get/upsert remain backed by the complete authoritative record.
final class _CompactDetailsStore implements ImportedLibraryStore {
  final MemoryImportedLibraryStore durable = MemoryImportedLibraryStore();
  bool hideStoredChapter = false;

  @override
  Future<void> open() => durable.open();

  @override
  Future<void> close() => durable.close();

  @override
  Future<List<ImportedLibraryEntry>> list() async =>
      HomeProjectionSnapshot.fromJson(HomeProjectionSnapshot(
        entries: await durable.list(),
        savedComics: const <SavedComicRecord>[],
        categories: const <LibraryCategory>[],
        preferences: const <ComicPreference>[],
        readStates: const <ChapterReadState>[],
        sourcePreferences: const <ComicSourcePreference>[],
        versionRelations: const <ComicVersionRelation>[],
      ).toJson()).entries;

  @override
  Future<ImportedLibraryEntry?> get(String sourceId, String chapterId) async =>
      hideStoredChapter ? null : await durable.get(sourceId, chapterId);

  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) {
    hideStoredChapter = false;
    return durable.upsertChapter(chapter);
  }

  @override
  Future<List<SavedComicRecord>> listSavedComics() => durable.listSavedComics();

  @override
  Future<void> upsertSavedComic(SavedComicRecord comic) =>
      durable.upsertSavedComic(comic);

  @override
  Future<List<LibraryCategory>> listCategories() => durable.listCategories();

  @override
  Future<List<ComicPreference>> listComicPreferences() =>
      durable.listComicPreferences();

  @override
  Future<void> saveComicPreference(ComicPreference preference) =>
      durable.saveComicPreference(preference);

  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() =>
      durable.listAllChapterReadStates();

  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() =>
      durable.listSourcePreferences();

  @override
  Future<void> saveSourcePreference(ComicSourcePreference preference) =>
      durable.saveSourcePreference(preference);

  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) => durable.listMigrationIssues(includeAcknowledged: includeAcknowledged);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final scenario in <String>[
    'valid known count', 'valid unknown count', 'changed revision',
    'changed known count', 'remaining placeholder', 'missing durable record',
    'legacy locator',
  ]) {
    testWidgets('details chapter preparation hydrates $scenario', (tester) async {
      final store = _CompactDetailsStore();
      await store.open();
      addTearDown(store.close);
      final catalogChapter = _chapter(
        revision: scenario == 'changed revision' ? 'r2' : 'r1',
        pageCount: scenario == 'valid unknown count' ? 0
            : scenario == 'changed known count' ? 3 : 2,
      );
      final source = _DetailsSource(catalogChapter);
      final original = ImportedChapterRecord.remote(
        comic: _comic, manifest: _manifest(_chapter()),
        importedAt: DateTime.utc(2026, 1, 1),
      );
      final stored = original.copyWith(pages: <ImportedPageRecord>[
        original.pages.first,
        ImportedPageRecord.fromJson(<String, Object?>{
          ...original.pages.last.toJson(),
          'sourceId': scenario == 'remaining placeholder'
              ? 'zic-home-snapshot-page:1'
              : scenario == 'legacy locator'
                  ? 'venera-resource://expired-runtime/page'
                  : original.pages.last.sourceId,
        }),
      ]);
      await store.durable.upsertChapter(stored);
      final progress = ReadingProgress(
        sourceId: _sourceId, comicId: _comicId, chapterId: _chapterId,
        pageIndex: 1, subPageOffset: 0.4, readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      await store.durable.saveProgress(progress);
      await store.durable.upsertSavedComic(SavedComicRecord.fromManifest(
        await source.loadComic(_comicId),
      ));
      await store.durable.saveComicPreference(ComicPreference.defaults(
        sourceId: _sourceId, comicId: _comicId,
        sourceKind: ComicSourceKind.remote,
      ).copyWith(inShelf: true));
      await tester.pumpWidget(App(
        libraryStore: store, comicSources: <BrowsableComicSource>[source],
        persistHomeProjectionSnapshot: false,
      ));
      for (var frame = 0; frame < 80 && find.text(_comic.title).evaluate().isEmpty;
          frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text(_comic.title), findsOneWidget);
      await tester.longPress(find.text(_comic.title));
      final route = find.byType(details.LocalComicDetailsScreen);
      for (var frame = 0; frame < 80 && route.evaluate().isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(route, findsOneWidget);
      final screen = tester.widget<details.LocalComicDetailsScreen>(route);
      expect(chapterHasHomeProjectionSnapshotPagePlaceholders(
          screen.initialLibrary.chapters.single.chapter), isTrue);
      expect(screen.ensureSourceChapter, isNotNull);
      store.hideStoredChapter = scenario == 'missing durable record';

      final prepared = await screen.ensureSourceChapter!(
        source, _comic, catalogChapter,
      );

      final valid = scenario.startsWith('valid');
      expect(source.chapterLoads, valid ? 0 : 1);
      expect(prepared.progress!.toJson(), progress.toJson());
      final persisted = (await store.durable.get(_sourceId, _chapterId))!;
      if (valid) {
        expect(prepared.chapter.toJson(), stored.toJson());
        expect(persisted.chapter.toJson(), stored.toJson());
      } else {
        expect(prepared.chapter.sourceRevision, catalogChapter.sourceRevision);
        expect(prepared.chapter.pages.length,
            catalogChapter.pageCount > 0 ? catalogChapter.pageCount : 2);
        expect(prepared.chapter.importedAt, isNot(stored.importedAt));
        expect(chapterRequiresSourceLocatorRefresh(prepared.chapter), isFalse);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
