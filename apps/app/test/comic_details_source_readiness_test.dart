import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/comic_details.dart' as details;

final class _Source extends Fake implements BrowsableComicSource {
  @override
  String get sourceId => 'deferred-source';
}

final class _Fixture {
  final ready = Completer<BrowsableComicSource?>();
  final source = _Source();
  BrowsableComicSource? active;
  ImportedLibraryEntry? opened;
  final errors = <Object>[];
  var ensureCalls = 0;

  ImportedLibraryEntry entry(String chapterId) => ImportedLibraryEntry(
        chapter: ImportedChapterRecord(
          directoryId: 'deferred-directory',
          displayName: chapterId,
          sourceId: source.sourceId,
          comicId: 'deferred-comic',
          comicTitle: 'Deferred comic',
          chapterId: chapterId,
          sourceRevision: 'revision-$chapterId',
          sequence: chapterId == 'cached' ? 0 : 1,
          pages: const <ImportedPageRecord>[
            ImportedPageRecord(
              displayName: 'page.png',
              sourceId: 'memory://page.png',
              contentKindHint: ContentKindHint.png,
            ),
          ],
        ),
      );

  Widget build() {
    final cached = entry('cached');
    final snapshot = details.ComicDetailsLibrarySnapshot(
      chapters: <ImportedLibraryEntry>[cached],
      sourceChapters: <Chapter>[
        cached.chapter.toManifest().chapter,
        entry('uncached').chapter.toManifest().chapter,
      ],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: 'deferred-comic',
        sourceKind: ComicSourceKind.remote,
      ),
    );
    return MaterialApp(
      home: details.LocalComicDetailsScreen(
        comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[cached]),
        initialLibrary: snapshot,
        categories: const <LibraryCategory>[],
        loadCover: ({
          required String sourceId,
          required String comicId,
          required Uri? coverUri,
          required ImportedLibraryEntry? fallbackChapter,
          required String resourceRole,
        }) async => MemoryEncodedResourceSource(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        )),
        reloadLibrary: ({required bool refreshContent}) async => snapshot,
        onPreferenceChanged: (_) async {},
        onReadChanged: (_, __) async {},
        onOpenChapter: (
          load, {
          required bool refreshRemote,
          required String title,
          int? initialPageIndex,
        }) async {
          try {
            opened = await load();
          } on Object catch (error) {
            errors.add(error);
          }
          return null;
        },
        onDownloadChapter: (_) async {},
        inspectChapterDownload: (entry) async =>
            ChapterDownloadSnapshot.idle(entry),
        downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
        onDownloadComic: (_) async {},
        resolveSource: (_) => active,
        sourceReady: ready.future,
        ensureSourceChapter: (resolved, comic, chapter) async {
          ensureCalls++;
          expect(identical(resolved, active), isTrue,
              reason: 'activation completion must use the current source');
          return entry(chapter.chapterId);
        },
      ),
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  _Fixture fixture,
  String chapterId,
) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(fixture.build());
  await tester.pumpAndSettle();
  final row = find.byKey(
    details.comicDetailsChapterKey(fixture.source.sourceId, chapterId),
  );
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('uncached chapter waits for existing source activation',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture, 'uncached');
    expect(fixture.errors, isEmpty,
        reason: 'pending activation must not be reported as unavailable');
    expect(fixture.opened, isNull);
    expect(fixture.ensureCalls, 0);

    fixture.active = fixture.source;
    fixture.ready.complete(_Source());
    await tester.pumpAndSettle();
    expect(fixture.errors, isEmpty);
    expect(fixture.opened?.chapter.chapterId, 'uncached');
    expect(fixture.ensureCalls, 1);
  });

  testWidgets('cached chapter does not wait for source activation',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture, 'cached');
    expect(fixture.ready.isCompleted, isFalse);
    expect(fixture.opened?.chapter.chapterId, 'cached');
    expect(fixture.errors, isEmpty);
    expect(fixture.ensureCalls, 0);
    fixture.ready.complete(null);
    await tester.pumpAndSettle();
  });

  testWidgets('unavailable activation fails once without chapter requests',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture, 'uncached');
    expect(fixture.errors, isEmpty);
    fixture.ready.complete(null);
    await tester.pumpAndSettle();
    expect(fixture.errors, hasLength(1));
    expect(fixture.errors.single, isA<StateError>());
    expect(fixture.ensureCalls, 0);
    await tester.pump(const Duration(seconds: 10));
    expect(fixture.errors, hasLength(1));
  });

  testWidgets('disposed details does not request a chapter after activation',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture, 'uncached');
    expect(fixture.errors, isEmpty);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    fixture.active = fixture.source;
    fixture.ready.complete(fixture.source);
    await tester.pumpAndSettle();
    expect(fixture.opened, isNull);
    expect(fixture.ensureCalls, 0);
    expect(fixture.errors.single, isA<Failure>().having(
      (error) => error.code, 'code', ErrorCode.cancelled,
    ));
  });

  testWidgets('activation result does not replace live source authority',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture, 'uncached');
    fixture.ready.complete(fixture.source);
    await tester.pumpAndSettle();
    expect(fixture.errors.single, isA<StateError>());
    expect(fixture.opened, isNull);
    expect(fixture.ensureCalls, 0);
  });
}
