import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/home_version_reuse_lifecycle.dart';

void main() {
  test('in-flight relation read retries after library generation adoption',
      () async {
    final firstLibrary = _BlockingVersionRelationStore();
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    final session = HomeLibrarySession(
      library: firstLibrary,
      chapterDownloads: firstDownloads,
      wholeComicDownloads: firstQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final lifecycle = _lifecycle(session);
    await session.ready;
    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'old-comic',
        successorComicId: 'stale-successor',
        predecessorTitle: 'Old comic',
        discoveredAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final secondLibrary = MemoryImportedLibraryStore();
    await secondLibrary.open();
    await secondLibrary.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'old-comic',
        successorComicId: 'current-successor',
        predecessorTitle: 'Old comic',
        discoveredAt: DateTime.utc(2026, 1, 2),
      ),
    );
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      if (!firstLibrary.releaseSuccessorRead.isCompleted) {
        firstLibrary.releaseSuccessorRead.complete();
      }
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    final stateFuture = lifecycle.loadVersionState(
      _VersionSource(),
      'Old comic',
      'old-comic',
    );
    await firstLibrary.successorReadStarted.future;

    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    firstLibrary.releaseSuccessorRead.complete();

    final state = await stateFuture;
    expect(
      state.successors.map((item) => item.comicId),
      contains('current-successor'),
    );
    expect(
      state.successors.map((item) => item.comicId),
      isNot(contains('stale-successor')),
    );
    await state.backgroundRefresh;
  });

  test('version lifecycle follows the session library generation', () async {
    final firstLibrary = MemoryImportedLibraryStore();
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    final session = HomeLibrarySession(
      library: firstLibrary,
      chapterDownloads: firstDownloads,
      wholeComicDownloads: firstQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final lifecycle = HomeVersionReuseLifecycle(
      session: session,
      loadRemoteEntrySnapshot: (entry, {control}) async => entry,
      verifiedPageReuseIdentity: ({
        required sourceId,
        required locator,
        control,
      }) async =>
          null,
      requiresSourceLocatorRefresh: (_) => false,
      scheduleMetadataTask: ({
        required key,
        required priority,
        required task,
      }) =>
          false,
      trace: const NoopTraceSink(),
      monotonicMicros: () => 0,
    );
    await session.ready;

    final secondLibrary = MemoryImportedLibraryStore();
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });
    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'old-comic',
        successorComicId: 'new-comic',
        predecessorTitle: 'Old comic',
        discoveredAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final state = await lifecycle.loadVersionState(
      _VersionSource(),
      'Old comic',
      'old-comic',
    );

    expect(state.successors.map((item) => item.comicId), contains('new-comic'));
    expect(state.predecessors, isEmpty);
    await state.backgroundRefresh;
  });
}

HomeVersionReuseLifecycle _lifecycle(HomeLibrarySession session) =>
    HomeVersionReuseLifecycle(
      session: session,
      loadRemoteEntrySnapshot: (entry, {control}) async => entry,
      verifiedPageReuseIdentity: ({
        required sourceId,
        required locator,
        control,
      }) async =>
          null,
      requiresSourceLocatorRefresh: (_) => false,
      scheduleMetadataTask: ({
        required key,
        required priority,
        required task,
      }) =>
          false,
      trace: const NoopTraceSink(),
      monotonicMicros: () => 0,
    );

final class _BlockingVersionRelationStore
    implements ImportedLibraryStore, ComicVersionRelationStore {
  final MemoryImportedLibraryStore _inner = MemoryImportedLibraryStore();
  final Completer<void> successorReadStarted = Completer<void>();
  final Completer<void> releaseSuccessorRead = Completer<void>();

  @override
  Future<void> open() => _inner.open();

  @override
  Future<List<ImportedLibraryEntry>> list() => _inner.list();

  @override
  Future<List<SavedComicRecord>> listSavedComics() => _inner.listSavedComics();

  @override
  Future<List<LibraryCategory>> listCategories() => _inner.listCategories();

  @override
  Future<List<ComicPreference>> listComicPreferences() =>
      _inner.listComicPreferences();

  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() =>
      _inner.listSourcePreferences();

  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() =>
      _inner.listAllChapterReadStates();

  @override
  Future<List<ComicVersionRelation>> listAllComicVersionRelations() =>
      _inner.listAllComicVersionRelations();

  @override
  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  ) =>
      _inner.listComicVersionPredecessors(sourceId, successorComicId);

  @override
  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  ) async {
    final result = await _inner.listComicVersionSuccessors(
      sourceId,
      predecessorComicId,
    );
    if (!successorReadStarted.isCompleted) {
      successorReadStarted.complete();
    }
    await releaseSuccessorRead.future;
    return result;
  }

  @override
  Future<void> saveComicVersionRelation(ComicVersionRelation relation) =>
      _inner.saveComicVersionRelation(relation);

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _VersionSource implements BrowsableComicSource, ComicVersionSource {
  @override
  String get sourceId => 'fixture';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Fixture',
        language: 'en',
        website: Uri.parse('https://example.invalid'),
      );

  @override
  bool get supportsComicVersions => true;

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async =>
      const <SourceComicVersion>[];

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async =>
      SourceBrowsePage(
        items: const <SourceComicSummary>[],
        offset: offset,
        hasMore: false,
      );

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw StateError('not used by this fixture');

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw StateError('not used by this fixture');

  @override
  Future<Uint8List> loadResource(Uri uri) =>
      throw StateError('not used by this fixture');
}
