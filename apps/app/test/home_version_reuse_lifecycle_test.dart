import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/home_version_reuse_lifecycle.dart';

void main() {
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
