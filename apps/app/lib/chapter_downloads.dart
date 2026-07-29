import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

abstract interface class ChapterDownloadService {
  Future<void> download(ImportedLibraryEntry entry);

  Future<bool> isDownloaded(ImportedLibraryEntry entry);

  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex);

  Future<void> close();
}

typedef ChapterPageLoader = Future<Uint8List> Function(
  ImportedLibraryEntry entry,
  int pageIndex,
);

/// Deterministic in-memory implementation used when the application has no
/// durable platform store (for example widget tests). It still owns complete
/// page bytes, so reporting a chapter as downloaded can never route Reader to
/// a missing artifact.
final class MemoryChapterDownloadService implements ChapterDownloadService {
  MemoryChapterDownloadService({required ChapterPageLoader pageLoader})
      : _pageLoader = pageLoader;

  final ChapterPageLoader _pageLoader;
  final Map<String, List<Uint8List>> _chapters =
      <String, List<Uint8List>>{};
  bool _closed = false;

  @override
  Future<void> download(ImportedLibraryEntry entry) async {
    _requireOpen();
    final pages = <Uint8List>[];
    for (var index = 0; index < entry.chapter.pages.length; index++) {
      pages.add(Uint8List.fromList(await _pageLoader(entry, index)));
    }
    _chapters[_identity(entry)] = List<Uint8List>.unmodifiable(pages);
  }

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async {
    _requireOpen();
    final pages = _chapters[_identity(entry)];
    return pages != null && pages.length == entry.chapter.pages.length;
  }

  @override
  Future<Uint8List> readPage(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) async {
    _requireOpen();
    final pages = _chapters[_identity(entry)];
    if (pages == null) {
      throw StateError('requested chapter is not downloaded');
    }
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw RangeError.index(pageIndex, pages, 'pageIndex');
    }
    return Uint8List.fromList(pages[pageIndex]);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _chapters.clear();
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('chapter download service is closed');
    }
  }
}

final class PersistentChapterDownloadService
    implements ChapterDownloadService {
  PersistentChapterDownloadService._({
    required DownloadRegistry registry,
    required SqliteIndex index,
    required IoTransport transport,
  })  : _registry = registry,
        _index = index,
        _transport = transport;

  static Future<PersistentChapterDownloadService> open(String root) async {
    final layout = CacheLayout('$root/offline_chapters');
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    final registry = DownloadRegistry(
      layout: layout,
      clock: SystemClock(),
      index: index,
    );
    await registry.restoreIndexed();
    return PersistentChapterDownloadService._(
      registry: registry,
      index: index,
      transport: IoTransport(
        http: HttpTransport(userAgent: 'zic/0.24.0'),
      ),
    );
  }

  final DownloadRegistry _registry;
  final SqliteIndex _index;
  final IoTransport _transport;
  bool _closed = false;

  @override
  Future<void> download(ImportedLibraryEntry entry) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    for (final page in manifest.pages) {
      final id = _downloadId(manifest, page);
      final session = _registry.get(id);
      await session.restore();
      if (session.state == DownloadState.promoted) {
        continue;
      }
      await DownloadJob(transport: _transport, session: session).run(
        expectedChecksum: page.checksum,
      );
    }
  }

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    for (final page in manifest.pages) {
      final session = _registry.get(_downloadId(manifest, page));
      await session.restore();
      if (session.state != DownloadState.promoted) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<Uint8List> readPage(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    if (pageIndex < 0 || pageIndex >= manifest.pages.length) {
      throw RangeError.index(pageIndex, manifest.pages, 'pageIndex');
    }
    final session = _registry.get(
      _downloadId(manifest, manifest.pages[pageIndex]),
    );
    await session.restore();
    if (session.state != DownloadState.promoted) {
      throw StateError('requested page is not downloaded');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in session.artifact.readChunks()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _registry.dispose();
    await _index.close();
    _transport.close(force: true);
  }

  DownloadId _downloadId(ChapterManifest manifest, PageAsset page) =>
      DownloadId(
        content: ContentId(
          sourceId: manifest.sourceId,
          comicId: manifest.comicId,
          chapterId: page.chapterId,
          pageId: page.pageId,
        ),
        sourceRevision: manifest.chapter.sourceRevision,
        canonicalUri: page.uri,
      );

  void _requireOpen() {
    if (_closed) {
      throw StateError('chapter download service is closed');
    }
  }
}

String _identity(ImportedLibraryEntry entry) =>
    '${entry.chapter.sourceId}\u0000${entry.chapter.chapterId}'
    '\u0000${entry.chapter.sourceRevision}';
