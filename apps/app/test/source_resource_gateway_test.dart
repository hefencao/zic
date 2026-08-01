import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/source_resource_gateway.dart';

void main() {
  test('gateway binds source access atomically and unbinds on close', () async {
    final source = _Source();
    final downloads = _RecordingDownloads();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );

    gateway.bindTo(downloads);
    final access = downloads.access;
    expect(access, isNotNull);
    expect(
      await access!.loadBytes!(
        source.sourceId,
        Uri.parse('venera-resource:durable'),
      ),
      <int>[1, 2, 3],
    );
    expect(source.loads, 1);

    gateway.close();
    expect(downloads.access, isNull);
  });

  test('gateway rejects legacy Venera tokens before source dispatch', () async {
    final source = _Source();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (_) => source,
    );
    addTearDown(gateway.close);

    expect(
      () => gateway.loadBytes(
        source.sourceId,
        Uri.parse('venera-resource://7'),
      ),
      throwsStateError,
    );
    expect(source.loads, 0);
  });
}

final class _Source implements BrowsableComicSource {
  int loads = 0;

  @override
  String get sourceId => 'venera:test';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Venera fixture',
        language: 'all',
        website: Uri.https('example.invalid', '/'),
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      throw UnimplementedError();

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    loads += 1;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}

final class _RecordingDownloads
    implements ChapterDownloadService, ConfigurableChapterResourceAccess {
  ChapterResourceAccess? access;

  @override
  void setChapterResourceAccess(ChapterResourceAccess? value) {
    access = value;
  }

  @override
  Stream<ChapterDownloadSnapshot> get changes => const Stream.empty();

  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> delete(ImportedLibraryEntry entry) async {}

  @override
  Future<void> download(ImportedLibraryEntry entry) async {}

  @override
  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry) =>
      throw UnimplementedError();

  @override
  Future<List<ChapterDownloadSnapshot>> inspectMany(
    Iterable<ImportedLibraryEntry> entries,
  ) async =>
      const <ChapterDownloadSnapshot>[];

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async => false;

  @override
  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex) =>
      throw UnimplementedError();

  @override
  Future<void> retry(ImportedLibraryEntry entry) async {}
}
