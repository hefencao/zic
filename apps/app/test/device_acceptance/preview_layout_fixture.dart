import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/comic_details.dart' as details;

const previewFixtureSourceId = 'preview-layout-fixture';
const previewFixtureComicId = 'preview-layout-fixture-comic';

Future<Map<String, Uint8List>> previewFixtureImages(List<Size> dimensions) async {
  final result = <String, Uint8List>{};
  for (var index = 0; index < dimensions.length; index++) {
    final size = dimensions[index];
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.primaries[index % Colors.primaries.length], BlendMode.src);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 3), Paint()..color = Colors.white);
    canvas.drawRect(Rect.fromLTWH(0, size.height - 3, size.width, 3),
      Paint()..color = Colors.black);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG fixture encoding failed');
      result['https://fixture.invalid/preview-$index.png'] = bytes.buffer.asUint8List(
        bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  return result;
}

Widget previewLayoutFixture({required List<Size> dimensions,
  required Map<String, Uint8List> images, int maximum = 4, Size? logicalView}) {
  final manifest = ComicManifest(
    comic: const Comic(sourceId: previewFixtureSourceId,
      comicId: previewFixtureComicId, title: '预览高度验收',
      authors: <String>[], readingDirection: ReadingDirection.ltr),
    chapters: const <Chapter>[],
    preview: ComicPreviewPage(items: <ComicPreviewAsset>[
      for (var index = 0; index < dimensions.length; index++)
        ComicPreviewAsset(uri: Uri.parse('https://fixture.invalid/preview-$index.png'),
          width: dimensions[index].width.toInt(), height: dimensions[index].height.toInt()),
    ]),
  );
  final source = _PreviewSource(manifest);
  final snapshot = details.ComicDetailsLibrarySnapshot(
    chapters: const <ImportedLibraryEntry>[], sourceChapters: const <Chapter>[],
    readStates: const <String, ChapterReadState>{}, sourceComic: manifest.comic,
    sourceManifest: manifest,
    preference: ComicPreference.defaults(sourceId: previewFixtureSourceId,
      comicId: previewFixtureComicId),
  );
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    builder: logicalView == null ? null : (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: logicalView,
        padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero), child: child!),
    home: details.RemoteComicDetailsScreen(
      source: source,
      summary: const SourceComicSummary(sourceId: previewFixtureSourceId,
        comicId: previewFixtureComicId, title: '预览高度验收',
        authors: <String>[], tags: <String>[], coverUri: null),
      initialLibrary: snapshot, categories: const <LibraryCategory>[],
      previewMaxItemsPerRow: maximum,
      loadCover: ({required String sourceId, required String comicId,
          required Uri? coverUri, required ImportedLibraryEntry? fallbackChapter,
          required String resourceRole}) async =>
        MemoryEncodedResourceSource(images[coverUri.toString()]!),
      reloadLibrary: ({required bool refreshContent}) async => snapshot,
      ensureSourceChapter: (_, __, ___) async =>
        throw StateError('Preview fixture must not prepare chapters'),
      persistComic: (_, __) async {}, onPreferenceChanged: (_) async {},
      onReadChanged: (_, __) async {},
      onOpenChapter: (_, {required bool refreshRemote, required String title,
          int? initialPageIndex}) async => null,
      onDownloadChapter: (_) async {},
      inspectChapterDownload: (chapter) async => ChapterDownloadSnapshot.idle(chapter),
      downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
      onDownloadComic: (_) async {},
    ),
  );
}

final class _PreviewSource implements BrowsableComicSource, ComicPreviewSource {
  _PreviewSource(this.manifest);
  final ComicManifest manifest;
  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
    sourceId: previewFixtureSourceId, name: 'Preview fixture',
    language: 'en', website: Uri.https('fixture.invalid', '/'));
  @override
  String get sourceId => previewFixtureSourceId;
  String get displayName => 'Preview fixture';
  @override
  bool get supportsComicPreview => true;
  @override
  Future<ComicManifest> loadComic(String comicId) async => manifest;
  @override
  Future<ComicPreviewPage> loadComicPreview(String comicId, {String? nextToken}) async =>
    manifest.preview!;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Unsupported preview-fixture operation: ${invocation.memberName}');
}
