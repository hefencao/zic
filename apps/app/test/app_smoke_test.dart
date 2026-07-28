import 'dart:io';

import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/demo_home.dart';
import 'package:zic/main.dart';
import 'package:zic/static_demo.dart';
import 'package:zic/webp_demo.dart';

File _nativeFixture(String name) {
  final candidates = <File>[
    File('native/media_core/testdata/$name'),
    File('../../native/media_core/testdata/$name'),
  ];
  return candidates.firstWhere(
    (file) => file.existsSync(),
    orElse: () => throw StateError('Missing native fixture: $name'),
  );
}

Future<void> _pumpUntilAbsent(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 60,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (finder.evaluate().isEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder to disappear');
}

Future<WebpPreviewState> _pumpUntilPreviewPhase(
  WidgetTester tester,
  WebpPreviewPhase phase, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(const Duration(milliseconds: 10));
    final finder = find.byKey(webpPreviewStateKey);
    if (finder.evaluate().isEmpty) {
      continue;
    }
    final region = tester.widget<WebpPreviewStateRegion>(finder);
    if (region.state.phase == phase) {
      return region.state;
    }
  }
  final regions = find.byKey(webpPreviewStateKey).evaluate();
  if (regions.isNotEmpty) {
    final state = tester
        .widget<WebpPreviewStateRegion>(
          find.byKey(webpPreviewStateKey),
        )
        .state;
    throw TestFailure(
      'Preview never reached ${phase.name}; '
      'actual=${state.phase.name}, error=${state.error}',
    );
  }
  throw TestFailure('Preview state region was not mounted');
}

ChapterManifest _mediaChapterFixture() {
  return ChapterManifest(
    sourceId: 'test-source',
    comicId: 'test-comic',
    chapter: const Chapter(
      chapterId: 'test-media-chapter',
      comicId: 'test-comic',
      title: 'Test media chapter',
      sequence: 1,
      pageCount: 1,
      sourceRevision: 'test-r1',
    ),
    pages: <PageAsset>[
      PageAsset(
        pageId: 'test-webp',
        chapterId: 'test-media-chapter',
        index: 0,
        uri: Uri.parse('assets/demo/animated/finite_loop.webp'),
        contentKindHint: ContentKindHint.webp,
        animatedHint: true,
      ),
    ],
    readingDirection: ReadingDirection.ltr,
  );
}

PickedWebpFolder _folderFixture() {
  final first = _nativeFixture('finite_loop.webp');
  final second = _nativeFixture('partial_blend.webp');
  return PickedWebpFolder(
    directoryPath: first.parent.path,
    displayName: 'chapter',
    files: <PickedWebp>[
      PickedWebp(
        file: XFile.fromData(
          first.readAsBytesSync(),
          path: first.path,
        ),
        displayName: '001.webp',
      ),
      PickedWebp(
        file: XFile.fromData(
          second.readAsBytesSync(),
          path: second.path,
        ),
        displayName: '002.webp',
      ),
    ],
  );
}

const _catalogEntries = <WebpDemoEntry>[
  WebpDemoEntry(
    id: 'infinite-basic',
    title: 'Infinite',
    description: 'test',
    asset: 'assets/demo/animated/animated.webp',
    byteLength: 140,
    frameCount: 2,
    loopCount: 0,
  ),
  WebpDemoEntry(
    id: 'finite-loop',
    title: 'Finite',
    description: 'test',
    asset: 'assets/demo/animated/finite_loop.webp',
    byteLength: 140,
    frameCount: 2,
    loopCount: 2,
  ),
  WebpDemoEntry(
    id: 'partial-blend',
    title: 'Partial blend',
    description: 'test',
    asset: 'assets/demo/animated/partial_blend.webp',
    byteLength: 188,
    frameCount: 2,
    loopCount: 0,
  ),
];

void main() {
  testWidgets('home exposes product entry points by semantic identity', (
    tester,
  ) async {
    await tester.pumpWidget(const App());
    await tester.pump();

    expect(find.byKey(staticDemoEntryKey), findsOneWidget);
    expect(find.byKey(mediaPipelineReaderEntryKey), findsOneWidget);
    expect(find.byKey(bundledWebpEntryKey), findsOneWidget);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
    expect(find.byKey(localWebpFolderImportKey), findsOneWidget);
  });

  testWidgets('static entry pushes its keyed route', (tester) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.byKey(staticDemoEntryKey));
    await tester.pump();

    expect(
      find.byKey(staticDemoScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('Reader entry pushes the media pipeline route', (tester) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.byKey(mediaPipelineReaderEntryKey));
    await tester.pump();

    expect(
      find.byKey(mediaPipelineReaderScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('Reader screen hosts the real WebP media component', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaPipelineReaderScreen(
          chapterLoader: () async => _mediaChapterFixture(),
        ),
      ),
    );

    final state = await _pumpUntilPreviewPhase(
      tester,
      WebpPreviewPhase.ready,
    );

    expect(state.info, isNotNull);
    expect(find.byKey(readerMediaWebpPageKey), findsOneWidget);
    expect(find.byKey(webpFlutterPreviewKey), findsOneWidget);
    expect(find.byKey(webpEngineControlKey), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('bundled WebP entry pushes the catalog route', (tester) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.byKey(bundledWebpEntryKey));
    await tester.pump();

    expect(
      find.byKey(webpCatalogScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('bundled catalog exposes entries by stable identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WebpCatalogScreen(
          entriesLoader: () async => _catalogEntries,
        ),
      ),
    );

    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find
          .byKey(webpCatalogEntryKey('infinite-basic'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    expect(find.byKey(webpCatalogEntryKey('infinite-basic')), findsOneWidget);
    expect(find.byKey(webpCatalogEntryKey('finite-loop')), findsOneWidget);
    expect(find.byKey(webpCatalogEntryKey('partial-blend')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('picked WebP navigates with the owned display name', (
    tester,
  ) async {
    final picked = PickedWebp(
      file: XFile('/virtual/route-source.webp'),
      displayName: 'route-owned.webp',
    );
    await tester.pumpWidget(App(picker: () async => picked));

    await tester.tap(find.byKey(localWebpImportKey));
    await tester.pump();

    final titleFinder = find.byKey(webpPreviewTitleKey, skipOffstage: false);
    expect(titleFinder, findsOneWidget);
    expect(tester.widget<Text>(titleFinder).data, 'route-owned.webp');
  });

  testWidgets('cancelled picker stays on home without opening a route', (
    tester,
  ) async {
    await tester.pumpWidget(App(picker: () async => null));

    await tester.tap(find.byKey(localWebpImportKey));
    await _pumpUntilAbsent(tester, find.byKey(localWebpPickerProgressKey));

    expect(find.byKey(webpPreviewScreenKey), findsNothing);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
    expect(find.byKey(localWebpPickerProgressKey), findsNothing);
  });

  testWidgets('picked folder navigates to the folder reader', (tester) async {
    final folder = _folderFixture();
    await tester.pumpWidget(App(folderPicker: () async => folder));

    final folderEntry = find.byKey(localWebpFolderImportKey);
    await tester.ensureVisible(folderEntry);
    await tester.pumpAndSettle();
    await tester.tap(folderEntry);
    await tester.pump();

    expect(
      find.byKey(webpFolderScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('folder reader switches WebP files by explicit identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: WebpFolderScreen(folder: _folderFixture())),
    );
    await _pumpUntilPreviewPhase(tester, WebpPreviewPhase.ready);

    expect(
      tester.widget<Text>(find.byKey(webpFolderCurrentFileKey)).data,
      '001.webp',
    );
    expect(
      tester.widget<Text>(find.byKey(webpFolderPositionKey)).data,
      '1 / 2',
    );
    expect(
      tester.widget<NativeWebpPlayer>(find.byType(NativeWebpPlayer)).sourceUri,
      Uri.file(_nativeFixture('finite_loop.webp').path),
    );

    await tester.tap(find.byKey(webpFolderNextKey));
    await tester.pump();
    await _pumpUntilPreviewPhase(tester, WebpPreviewPhase.ready);

    expect(
      tester.widget<Text>(find.byKey(webpFolderCurrentFileKey)).data,
      '002.webp',
    );
    expect(
      tester.widget<Text>(find.byKey(webpFolderPositionKey)).data,
      '2 / 2',
    );
    expect(
      tester.widget<NativeWebpPlayer>(find.byType(NativeWebpPlayer)).sourceUri,
      Uri.file(_nativeFixture('partial_blend.webp').path),
    );
  });

  testWidgets('cancelled folder picker stays on home', (tester) async {
    await tester.pumpWidget(App(folderPicker: () async => null));

    final folderEntry = find.byKey(localWebpFolderImportKey);
    await tester.ensureVisible(folderEntry);
    await tester.pumpAndSettle();
    await tester.tap(folderEntry);
    await _pumpUntilAbsent(
      tester,
      find.byKey(localWebpFolderPickerProgressKey),
    );

    expect(find.byKey(webpFolderScreenKey), findsNothing);
    expect(find.byKey(localWebpFolderImportKey), findsOneWidget);
  });
}
