import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    await tester.pump();

    expect(find.byKey(staticDemoEntryKey), findsOneWidget);
    expect(find.byKey(mediaPipelineReaderEntryKey), findsOneWidget);
    expect(find.byKey(bundledWebpEntryKey), findsOneWidget);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
    expect(find.byKey(localImageFolderImportKey), findsOneWidget);
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
    await tester.pump();

    expect(find.byKey(readerMediaWebpPageKey), findsOneWidget);
    expect(find.byType(NativeWebpPlayer), findsOneWidget);
    final state = tester.widget<WebpPreviewStateRegion>(
      find.byKey(webpPreviewStateKey),
    );
    expect(state.state.phase, WebpPreviewPhase.loading);
    expect(find.byKey(webpEngineControlKey), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    bytes.complete(_nativeFixture('finite_loop.webp').readAsBytesSync());
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

    await tester.tap(find.byKey(localWebpImportKey));
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

    await tester.tap(find.byKey(localWebpImportKey));
    await tester.pump();
    expect(find.byKey(localWebpPickerProgressKey), findsOneWidget);

    result.complete(null);
    await tester.pumpAndSettle();

    expect(find.byKey(webpPreviewScreenKey), findsNothing);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
    expect(find.byKey(localWebpPickerProgressKey), findsNothing);
  });

  testWidgets('picked folder navigates to the folder reader', (tester) async {
    final result = Completer<PickedImageFolder?>();
    final folder = _folderFixture();
    await tester.pumpWidget(App(folderPicker: () => result.future));

    final folderEntry = find.byKey(localImageFolderImportKey);
    await tester.ensureVisible(folderEntry);
    await tester.pumpAndSettle();
    await tester.tap(folderEntry);
    await tester.pump();
    expect(find.byKey(localImageFolderPickerProgressKey), findsOneWidget);

    result.complete(folder);
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(imageFolderScreenKey, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('folder reader switches mixed image files by explicit identity', (
    tester,
  ) async {
    final pending = <String, Completer<Uint8List>>{
      '001.webp': Completer<Uint8List>(),
      '002.bin': Completer<Uint8List>(),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: ImageFolderScreen(
          folder: _folderFixture(),
          bytesLoader: (image) => pending[image.displayName]!.future,
        ),
      ),
    );

    expect(
      tester.widget<Text>(find.byKey(imageFolderCurrentFileKey)).data,
      '001.webp · WebP',
    );
    expect(
      tester.widget<Text>(find.byKey(imageFolderPositionKey)).data,
      '1 / 2',
    );
    expect(
      tester.widget<LocalImagePlayer>(find.byType(LocalImagePlayer)).sourceUri,
      Uri.file(_nativeFixture('finite_loop.webp').path),
    );
    expect(
      tester
          .widget<ImagePreviewStateRegion>(
            find.byKey(imageFolderPreviewStateKey),
          )
          .state
          .phase,
      ImagePreviewPhase.loading,
    );

    await tester.tap(find.byKey(imageFolderNextKey));
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(imageFolderCurrentFileKey)).data,
      '002.bin · PNG',
    );
    expect(
      tester.widget<Text>(find.byKey(imageFolderPositionKey)).data,
      '2 / 2',
    );
    expect(
      tester.widget<LocalImagePlayer>(find.byType(LocalImagePlayer)).sourceUri,
      Uri.file('${_nativeFixture('finite_loop.webp').parent.path}/002.bin'),
    );
    expect(
      tester
          .widget<ImagePreviewStateRegion>(
            find.byKey(imageFolderPreviewStateKey),
          )
          .state
          .phase,
      ImagePreviewPhase.loading,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    pending['001.webp']!.complete(_folderBytes(_folderFixture().files.first));
    pending['002.bin']!.complete(_folderBytes(_folderFixture().files.last));
    await tester.pump();
  });

  testWidgets('cancelled folder picker stays on home', (tester) async {
    final result = Completer<PickedImageFolder?>();
    await tester.pumpWidget(App(folderPicker: () => result.future));

    final folderEntry = find.byKey(localImageFolderImportKey);
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
  });
}
