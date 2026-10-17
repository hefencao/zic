import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:telemetry/telemetry.dart';

import 'translation_runtime.dart';

ComicTranslationInputFile bindTranslationArchive(ComicTranslationInputFile file, {
  required PersistentDownloadArtifactStore store,
  required DownloadId id,
}) => ComicTranslationInputFile(path: file.path, release: file.release,
  archive: ComicTranslationArchiveAccess(
    read: () => store.readArtifactCompanion(id),
    write: (bytes) => store.writeArtifactCompanion(id, bytes),
  ));

/// Backfills cached results when the user downloads images after translating.
/// It owns only local archive work; the download service retains all transfers.
final class TranslationDownloadArchives {
  TranslationDownloadArchives({required this.composition, required this.library,
    required this.storageRoot, required this.trace, Future<void> Function()? initialize})
      : _initialize = initialize ?? initializeComicTranslation {
    _subscription = composition.chapterDownloads.changes.listen(_downloadChanged);
  }

  final PersistentDownloadComposition composition;
  final ImportedLibraryStore library;
  final String storageRoot;
  final TraceSink trace;
  final Future<void> Function() _initialize;
  late final StreamSubscription<ChapterDownloadSnapshot> _subscription;
  final Map<String, ChapterDownloadSnapshot> _pending = {};
  Future<void>? _working;
  bool _closed = false;

  void _downloadChanged(ChapterDownloadSnapshot snapshot) {
    if (_closed || snapshot.phase != ChapterDownloadPhase.complete || !snapshot.isManualDownload) return;
    final key = chapterDownloadIdentity(snapshot.sourceId, snapshot.comicId,
      snapshot.chapterId, snapshot.sourceRevision);
    _pending[key] = snapshot;
    _start();
  }

  void _start() {
    if (_closed || _working != null || _pending.isEmpty) return;
    _working = _drain().whenComplete(() {
      _working = null;
      _start();
    });
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final key = _pending.keys.first;
      final snapshot = _pending.remove(key)!;
      try {
        // Do not initialize translation or load models for ordinary downloads
        // when this application has never stored a translation.
        if (!await ComicTranslationStore.existsAt('$storageRoot/translation')) continue;
        await _initialize();
        final entry = await library.get(snapshot.sourceId, snapshot.chapterId);
        if (entry == null || entry.chapter.comicId != snapshot.comicId ||
            entry.chapter.sourceRevision != snapshot.sourceRevision) continue;
        final chapter = entry.chapter.toManifest();
        for (final page in chapter.pages) {
          final identity = ComicTranslationPageIdentity(
            imageKey: jsonEncode([snapshot.sourceRevision, page.uri.toString()]),
            sourceKey: snapshot.sourceId, comicId: snapshot.comicId,
            chapterId: snapshot.chapterId, pageIndex: page.index,
            mediaKind: page.animatedHint || page.contentKindHint == ContentKindHint.gif
                ? ComicTranslationMediaKind.animatedImage : ComicTranslationMediaKind.staticImage,
          );
          if (identity.mediaKind == ComicTranslationMediaKind.animatedImage) continue;
          final id = readerPageDownloadId(chapter, page);
          final input = await ComicTranslationInputResolver(openFile: (_) async {
            final lease = await composition.artifactCacheManager.openPresentationFile(id);
            return lease == null ? null : ComicTranslationInputFile(path: lease.path, release: lease.release);
          }).resolve(identity);
          if (input == null) continue;
          try {
            if (input.mediaKind == ComicTranslationMediaKind.animatedImage) continue;
            final bytes = await ComicTranslationStore.instance.exportPage(input.contentDigest);
            if (bytes != null) await composition.artifactStore.writeArtifactCompanion(id, bytes);
          } finally {
            await input.release();
          }
        }
      } on Object catch (error) {
        trace.record(TraceEvent(monotonicMicros: const SystemClock().nowMicros(),
          sessionId: 'translation-archives', kind: TraceEventKind.comicTranslation,
          payload: {'stage': 'archive-backfill-failed', 'errorType': error.runtimeType.toString()}));
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    await _subscription.cancel();
    await _working;
    if (_pending.isNotEmpty) await _drain();
  }
}
