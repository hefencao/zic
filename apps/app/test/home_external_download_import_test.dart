import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:zic/home_download_commands.dart';
import 'package:zic/home_library_session.dart';

void main() {
  test('Home import publishes local preferences, isolates title conflicts and resumes without duplicate records', () async {
    final root = await Directory.systemTemp.createTemp('zic-home-import-test-');
    addTearDown(() => root.delete(recursive: true));
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6jXcAAAAASUVORK5CYII=');
    for (final folder in ['A', 'B']) {
      final directory = await Directory('${root.path}/foreign/$folder').create(recursive: true);
      await File('${directory.path}/1.png').writeAsBytes(png);
      await File('${directory.path}/2.png').writeAsBytes([...png, 0]);
      await File('${directory.path}/ComicInfo.xml').writeAsString(
        '<ComicInfo><Title>Shared title</Title><PageCount>2</PageCount><Web>https://e-hentai.org/g/1/test/</Web></ComicInfo>');
    }
    final composition = await PersistentDownloadComposition.open('${root.path}/zic',
      indexPath: defaultChapterDownloadMetadataPath('${root.path}/zic'),
      transferNet: NetLane(maxActive: 5));
    addTearDown(composition.close);
    final library = SqliteImportedLibraryStore('${root.path}/zic/library.sqlite');
    await library.open();
    addTearDown(library.close);
    final queue = WholeComicDownloadQueue(downloads: composition.chapterDownloads);
    addTearDown(queue.close);
    final session = HomeLibrarySession(library: library,
      chapterDownloads: composition.chapterDownloads,
      downloadComposition: composition,
      wholeComicDownloads: queue,
      sources: const [], ownsLibrary: false, ownsChapterDownloads: false,
      ownsWholeComicDownloads: false);
    await session.ready;
    addTearDown(session.close);
    final commands = HomeDownloadCommands(session: session,
      ensureDurableServices: () async {}, ensurePlatformEnvironment: () async {},
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async => entry,
      refreshStaleChapter: (_) async => null);
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final scan = await ExternalDownloadScanner().scan(tree);
    expect(scan.comics, hasLength(2));
    final entries = <ImportedLibraryEntry>[];
    for (final comic in [...scan.comics, scan.comics.last]) {
      final prepared = await prepareExternalChapter(tree: tree, comic: comic,
        chapter: comic.chapters.single, stagingParent: Directory('${root.path}/staging'));
      try {
        entries.add(await commands.importLocalChapter(prepared, checkCancelled: () {}));
      } finally {
        await prepared.dispose();
      }
    }
    expect(session.entries, hasLength(2));
    expect(await library.list(), hasLength(2));
    expect(entries[2].chapter.importedAt, entries[1].chapter.importedAt);
    for (final entry in entries) {
      final preference = await library.getComicPreference(entry.chapter.sourceId, entry.chapter.comicId);
      expect(preference?.sourceKind, ComicSourceKind.local);
      expect(preference?.inShelf, true);
      expect((await composition.chapterDownloads.inspect(entry)).phase, ChapterDownloadPhase.complete);
    }
    final a = await composition.chapterDownloads.getDownloadPlacement(
      sourceId: entries[0].chapter.sourceId, comicId: entries[0].chapter.comicId);
    final b = await composition.chapterDownloads.getDownloadPlacement(
      sourceId: entries[1].chapter.sourceId, comicId: entries[1].chapter.comicId);
    expect(a?.relativeDirectory, isNot(b?.relativeDirectory));
    expect(await File('${root.path}/foreign/A/1.png').readAsBytes(), png);
    await Directory('${root.path}/foreign').delete(recursive: true);
    for (final entry in session.entries) {
      expect(await composition.chapterDownloads.readPage(entry, 0), png);
      expect(await composition.chapterDownloads.readPage(entry, 1), [...png, 0],
        reason: 'comic identity hashes must not merge distinct page bodies');
    }
  });
}
