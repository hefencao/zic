import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/demo_home.dart';
import 'package:zic/app.dart';
import 'package:zic/reader_runtime.dart';
import 'package:zic/static_demo.dart';
import 'package:zic/webp_demo.dart';



const _frameStep = Duration(milliseconds: 20);
const _readerRetentionSettleStep = Duration(milliseconds: 500);
const _readerRetentionSettleSteps = 300;

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(_frameStep);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> _disposePipelineReader(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Drive the real two-minute retained-session expiry through bounded fake
  // time steps. Interleaved pumps also drain observation timers and allow
  // file-I/O futures to settle without awaiting the composition-wide close
  // from inside Flutter's fake-async zone.
  for (var i = 0; i < _readerRetentionSettleSteps; i++) {
    await tester.pump(_readerRetentionSettleStep);
  }
}

Future<void> _expandDiagnostics(WidgetTester tester) async {
  final diagnostics = find.byKey(homeDiagnosticsKey);
  await _pumpUntilFound(tester, diagnostics);
  await tester.ensureVisible(diagnostics);
  await tester.tap(diagnostics);
  await tester.pumpAndSettle();
}

Future<void> _pumpUntilKeyText(
  WidgetTester tester,
  Key key,
  String expected, {
  int maxFrames = 60,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(_frameStep);
    final finder = find.byKey(key, skipOffstage: false);
    if (finder.evaluate().length == 1) {
      final widget = tester.widget<Text>(finder);
      if (widget.data == expected) {
        return;
      }
    }
  }
  throw TestFailure('Timed out waiting for $key to equal $expected');
}

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

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

PickedImageFolder _folderFixture() {
  final first = _nativeFixture('finite_loop.webp');
  return PickedImageFolder(
    directoryPath: first.parent.path,
    displayName: 'chapter',
    files: <PickedImage>[
      PickedImage(
        file: XFile(first.path),
        format: LocalImageFormat.webp,
        displayName: '001.webp',
      ),
      PickedImage(
        file: XFile('${first.parent.path}/002.bin'),
        format: LocalImageFormat.png,
        displayName: '002.bin',
      ),
    ],
  );
}

Future<Uint8List> _folderBytes(PickedImage image) async {
  return switch (image.format) {
    LocalImageFormat.webp =>
      _nativeFixture('finite_loop.webp').readAsBytesSync(),
    LocalImageFormat.png => _tinyPng(),
    _ => throw StateError('unexpected test image format: ${image.format}'),
  };
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
    await _pumpUntilFound(tester, find.byKey(localImageFolderImportKey));
    await _expandDiagnostics(tester);

    expect(find.byKey(staticDemoEntryKey), findsOneWidget);
    expect(find.byKey(mediaPipelineReaderEntryKey), findsOneWidget);
    expect(find.byKey(bundledWebpEntryKey), findsOneWidget);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
    expect(find.byKey(localImageFolderImportKey), findsOneWidget);
  });

  testWidgets('static entry pushes its keyed route', (tester) async {
    await tester.pumpWidget(const App());
    await _expandDiagnostics(tester);
    final entry = find.byKey(staticDemoEntryKey);
    await _pumpUntilFound(tester, entry);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();

    expect(
      find.byKey(staticDemoScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('Reader entry pushes the media pipeline route', (tester) async {
    await tester.pumpWidget(const App());
    await _expandDiagnostics(tester);
    final entry = find.byKey(mediaPipelineReaderEntryKey);
    await _pumpUntilFound(tester, entry);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();

    expect(
      find.byKey(mediaPipelineReaderScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('Reader screen hosts the real WebP media component', (
    tester,
  ) async {
    final bytes = Completer<Uint8List>();

    await tester.pumpWidget(
      MaterialApp(
        home: MediaPipelineReaderScreen(
          chapterLoader: () async => _mediaChapterFixture(),
          mediaBytesLoader: (asset, token) {
            token.throwIfCancelled();
            return bytes.future;
          },
        ),
      ),
    );
    final page = find.byKey(readerMediaWebpPageKey);
    await _pumpUntilFound(tester, page);

    expect(page, findsOneWidget);
    expect(find.byType(LocalImagePlayer), findsOneWidget);
    expect(find.byType(NativeWebpPlayer), findsNothing);
    final state = tester.widget<ImagePreviewStateRegion>(
      find.byKey(imageFolderPreviewStateKey),
    );
    expect(state.state.phase, ImagePreviewPhase.loading);
    expect(find.byKey(imagePageLoadingIndicatorKey), findsOneWidget);
    expect(find.byKey(webpEngineControlKey), findsNothing);

    bytes.complete(_nativeFixture('finite_loop.webp').readAsBytesSync());
    await _disposePipelineReader(tester);
  });

  testWidgets('bundled WebP entry pushes the catalog route', (tester) async {
    await tester.pumpWidget(const App());
    await _expandDiagnostics(tester);
    final entry = find.byKey(bundledWebpEntryKey);
    await _pumpUntilFound(tester, entry);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();

    expect(
      find.byKey(webpCatalogScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('bundled catalog exposes entries by stable identity', (
    tester,
  ) async {
    final entries = Completer<List<WebpDemoEntry>>();
    await tester.pumpWidget(
      MaterialApp(
        home: WebpCatalogScreen(entriesLoader: () => entries.future),
      ),
    );

    entries.complete(_catalogEntries);
    await tester.pump();

    expect(find.byKey(webpCatalogEntryKey('infinite-basic')), findsOneWidget);
    expect(find.byKey(webpCatalogEntryKey('finite-loop')), findsOneWidget);
    expect(find.byKey(webpCatalogEntryKey('partial-blend')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('picked WebP navigates with the owned display name', (
    tester,
  ) async {
    final result = Completer<PickedWebp?>();
    final picked = PickedWebp(
      file: XFile('/virtual/route-source.webp'),
      displayName: 'route-owned.webp',
    );
    await tester.pumpWidget(App(picker: () => result.future));
    await _expandDiagnostics(tester);

    final importEntry = find.byKey(localWebpImportKey);
    await _pumpUntilFound(tester, importEntry);
    await tester.ensureVisible(importEntry);
    await tester.tap(importEntry);
    await tester.pump();
    expect(find.byKey(localWebpPickerProgressKey), findsOneWidget);

    result.complete(picked);
    await tester.pump();
    await tester.pump();

    final titleFinder = find.byKey(webpPreviewTitleKey, skipOffstage: false);
    expect(titleFinder, findsOneWidget);
    expect(tester.widget<Text>(titleFinder).data, 'route-owned.webp');
  });

  testWidgets('cancelled picker stays on home without opening a route', (
    tester,
  ) async {
    final result = Completer<PickedWebp?>();
    await tester.pumpWidget(App(picker: () => result.future));
    await _expandDiagnostics(tester);

    final importEntry = find.byKey(localWebpImportKey);
    await _pumpUntilFound(tester, importEntry);
    await tester.ensureVisible(importEntry);
    await tester.tap(importEntry);
    await tester.pump();
    expect(find.byKey(localWebpPickerProgressKey), findsOneWidget);

    result.complete(null);
    await tester.pumpAndSettle();

    expect(find.byKey(webpPreviewScreenKey), findsNothing);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
    expect(find.byKey(localWebpPickerProgressKey), findsNothing);
  });

  testWidgets('imported library reopens at the last reading page', (
    tester,
  ) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final folder = _folderFixture();
    final record = imageFolderChapterRecord(folder);
    await store.upsertChapter(record);
    await store.saveProgress(
      ReadingProgress(
        sourceId: record.sourceId,
        comicId: record.comicId,
        chapterId: record.chapterId,
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 28),
      ),
    );

    await tester.pumpWidget(App(libraryStore: store));
    await tester.pump();

    final entry = find.byKey(historyChapterEntryKey(record.sourceId, record.chapterId));
    await _pumpUntilFound(tester, entry);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    final screen = find.byKey(imageFolderScreenKey, skipOffstage: false);
    await _pumpUntilFound(tester, screen);
    await tester.tap(screen);
    await _pumpUntilFound(
      tester,
      find.byKey(readerPageSubtitleKey, skipOffstage: false),
    );

    expect(
      find.byKey(imageFolderScreenKey, skipOffstage: false),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(
        find.byKey(readerPageSubtitleKey, skipOffstage: false),
      ).data,
      '002.bin · PNG',
    );

    await _disposePipelineReader(tester);
  });


  testWidgets('home omits the local directory maintenance surface', (
    tester,
  ) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final record = imageFolderChapterRecord(_folderFixture());
    await store.upsertChapter(record);

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(
      tester,
      find.byKey(localImageFolderImportKey),
    );

    expect(find.text('本地目录维护'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byTooltip('删除本地记录'), findsNothing);
  });

  testWidgets('picked folder navigates to the folder reader', (tester) async {
    final result = Completer<PickedImageFolder?>();
    final folder = _folderFixture();
    await tester.pumpWidget(App(folderPicker: () => result.future));

    final folderEntry = find.byKey(localImageFolderImportKey);
    await _pumpUntilFound(tester, folderEntry);
    await tester.ensureVisible(folderEntry);
    await tester.pumpAndSettle();
    await tester.tap(folderEntry);
    await tester.pump();
    expect(find.byKey(localImageFolderPickerProgressKey), findsOneWidget);

    result.complete(folder);
    await _pumpUntilFound(
      tester,
      find.byKey(imageFolderScreenKey, skipOffstage: false),
    );

    expect(
      find.byKey(imageFolderScreenKey, skipOffstage: false),
      findsOneWidget,
    );

    await _disposePipelineReader(tester);
  });

  testWidgets('folder reader switches mixed image files by explicit identity', (
    tester,
  ) async {
    final progress = <ReadingProgress>[];
    final pending = <String, Completer<Uint8List>>{
      '001.webp': Completer<Uint8List>(),
      '002.bin': Completer<Uint8List>(),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: ImageFolderScreen(
          folder: _folderFixture(),
          pipelineFactory: defaultLocalMediaPipelineFactory,
          bytesLoader: (image) => pending[image.displayName]!.future,
          onProgressChanged: progress.add,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(imageFolderScreenKey));
    await _pumpUntilFound(tester, find.byKey(readerPageSubtitleKey));

    expect(
      tester.widget<Text>(find.byKey(readerPageSubtitleKey)).data,
      '001.webp · WebP',
    );
    final firstPlayer = find.byKey(
      ValueKey<String>(
        'folder-image:${_folderFixture().files.first.sourceId}:webp:0',
      ),
    );
    expect(
      tester.widget<LocalImagePlayer>(firstPlayer).sourceUri,
      Uri.file(_nativeFixture('finite_loop.webp').path),
    );
    expect(
      tester
          .widget<ImagePreviewStateRegion>(
            find.descendant(
              of: firstPlayer,
              matching: find.byKey(imageFolderPreviewStateKey),
            ),
          )
          .state
          .phase,
      ImagePreviewPhase.loading,
    );

    final slider = tester.widget<Slider>(find.byKey(readerPageSliderKey));
    slider.onChanged!(1);
    slider.onChangeEnd!(1);
    await _pumpUntilKeyText(
      tester,
      readerPageSubtitleKey,
      '002.bin · PNG',
    );

    expect(
      tester.widget<Text>(find.byKey(readerPageSubtitleKey)).data,
      '002.bin · PNG',
    );
    expect(progress.last.pageIndex, 1);
    expect(progress.last.readerMode, ReaderMode.paged);
    final secondPlayer = find.byKey(
      ValueKey<String>(
        'folder-image:${_folderFixture().files.last.sourceId}:png:1',
      ),
    );
    expect(
      tester.widget<LocalImagePlayer>(secondPlayer).sourceUri,
      Uri.file('${_nativeFixture('finite_loop.webp').parent.path}/002.bin'),
    );
    expect(
      tester
          .widget<ImagePreviewStateRegion>(
            find.descendant(
              of: secondPlayer,
              matching: find.byKey(imageFolderPreviewStateKey),
            ),
          )
          .state
          .phase,
      ImagePreviewPhase.loading,
    );

    pending['001.webp']!.complete(_folderBytes(_folderFixture().files.first));
    pending['002.bin']!.complete(_folderBytes(_folderFixture().files.last));
    await _disposePipelineReader(tester);
  });

  testWidgets('cancelled folder picker stays on home', (tester) async {
    final result = Completer<PickedImageFolder?>();
    await tester.pumpWidget(App(folderPicker: () => result.future));

    final folderEntry = find.byKey(localImageFolderImportKey);
    await _pumpUntilFound(tester, folderEntry);
    await tester.ensureVisible(folderEntry);
    await tester.pumpAndSettle();
    await tester.tap(folderEntry);
    await tester.pump();
    expect(find.byKey(localImageFolderPickerProgressKey), findsOneWidget);

    result.complete(null);
    await tester.pumpAndSettle();

    expect(find.byKey(imageFolderScreenKey), findsNothing);
    expect(find.byKey(localImageFolderImportKey), findsOneWidget);
    expect(find.byKey(localImageFolderPickerProgressKey), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
