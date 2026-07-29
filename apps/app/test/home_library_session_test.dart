import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/chapter_downloads.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/whole_comic_downloads.dart';

void main() {
  test('home session owns durable projection outside DemoHome state', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;

    expect(session.loading, isFalse);
    expect(session.error, isNull);
    expect(session.entries, isEmpty);
    expect(session.savedComics, isEmpty);
    expect(session.activeSourceId, isNull);

    var notifications = 0;
    session.addListener(() => notifications++);
    final preference = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true);

    session.replacePreference(preference);

    expect(session.preferences[preference.identity]?.liked, isTrue);
    expect(notifications, 1);
  });
}
