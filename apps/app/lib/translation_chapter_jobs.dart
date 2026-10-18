import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/foundation.dart';
import 'package:local_media_bridge/local_media_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'translation_runtime.dart';
import 'translation_archives.dart';

typedef PreparedTranslationChapter = ({
  ImportedLibraryEntry entry,
  ChapterDownloadTransferRuntimeProvider? composition,
});

/// Application work survives Reader disposal. Downloads retain their existing
/// owner and NetLane; cancelling translation leaves a shared download intact.
final class AppTranslationChapterJobs extends ChangeNotifier {
  AppTranslationChapterJobs({Future<void> Function()? initialize})
      : _initialize = initialize ?? initializeComicTranslation;

  static final instance = AppTranslationChapterJobs();
  final Future<void> Function() _initialize;
  final Map<String, _ChapterJob> _jobs = {};

  static String keyFor(ImportedChapterRecord chapter) => chapterDownloadIdentity(
    chapter.sourceId, chapter.comicId, chapter.chapterId, chapter.sourceRevision);

  static String keyForManifest(ChapterManifest chapter) => chapterDownloadIdentity(
    chapter.sourceId, chapter.comicId, chapter.chapter.chapterId, chapter.chapter.sourceRevision);

  bool get hasActive => _jobs.values.any((job) => job.state.isActive);

  ComicTranslationChapterState? stateFor(String key) => _jobs[key]?.state;

  Future<void> start(ImportedLibraryEntry entry, {
    required Future<PreparedTranslationChapter> Function() prepare,
    required TraceSink trace,
  }) {
    final key = keyFor(entry.chapter);
    final existing = _jobs[key];
    if (existing?.state.isActive == true) return existing!.completion;
    if (_jobs.values.any((job) => job.state.isActive)) {
      throw StateError('已有整章预翻译任务，请先等待完成或取消');
    }
    final job = _ChapterJob(entry.chapter.pages.length);
    _jobs.remove(key);
    _jobs[key] = job;
    while (_jobs.length > 4) {
      _jobs.remove(_jobs.keys.first);
    }
    job.completion = _run(job, prepare, trace);
    notifyListeners();
    return job.completion;
  }

  Future<void> _run(_ChapterJob job,
      Future<PreparedTranslationChapter> Function() prepare, TraceSink trace) async {
    try {
      await _initialize();
      if (job.cancelled) return;
      ComicTranslationRuntime.instance.configure();
      if (!ComicTranslationEngineRegistry.instance.ready) {
        throw StateError('请先配置翻译模型与 API');
      }
      final prepared = await Future.any<PreparedTranslationChapter?>([
        prepare(), job.cancellation.future.then((_) => null),
      ]);
      if (prepared == null || job.cancelled) return;
      final chapter = prepared.entry.chapter;
      final manifest = chapter.toManifest();
      final settings = ComicTranslationSettings.instance;
      final preferences = settings.forComic(chapter.sourceId, chapter.comicId);
      final ocrVersion = ComicTranslationEngineRegistry.instance.ocrEngine?.modelVersion ?? '';
      final task = job.task = ComicTranslationChapterTask(
        pages: [for (final page in manifest.pages) ComicTranslationPageIdentity(
          imageKey: jsonEncode([chapter.sourceRevision, page.uri.toString()]),
          sourceKey: chapter.sourceId, comicId: chapter.comicId, chapterId: chapter.chapterId,
          pageIndex: page.index,
          mediaKind: ComicTranslationMediaKind.staticImage,
        )],
        sourceLanguage: preferences['sourceLanguage'] as String,
        targetLanguage: preferences['targetLanguage'] as String,
        detectedSourceLanguage: settings.detectedLanguage(chapter.sourceId, chapter.comicId, ocrVersion),
        onSourceLanguageDetected: (language) => settings.rememberLanguage(
          chapter.sourceId, chapter.comicId, language, ocrVersion),
        policy: ComicTranslationPolicy(
          ocrParameters: ComicOcrParameters.fromSettings(preferences),
          contextPages: preferences['contextPages'] as int,
          translateSoundEffects: preferences['translateSoundEffects'] == true,
          useCleanOverlay: preferences['useCleanOverlay'] == true,
        ),
        inputResolver: ComicTranslationInputResolver(openFile: (identity) async {
          final page = manifest.pages[identity.pageIndex];
          final lease = await prepared.composition?.artifactCacheManager
              .openPresentationFile(readerPageDownloadId(manifest, page));
          if (lease != null) return bindTranslationArchive(
            ComicTranslationInputFile(path: lease.path, release: lease.release),
            store: prepared.composition!.artifactStore, id: readerPageDownloadId(manifest, page));
          if (page.uri.scheme == 'content') {
            final document = await const LocalMediaBridge().openDocumentFile(page.uri.toString());
            return ComicTranslationInputFile(path: document.path, release: document.close);
          }
          return ComicTranslationInputFile.openLocalUri(page.uri);
        }),
        onDiagnostic: (identity, details) => trace.record(TraceEvent(
          monotonicMicros: const SystemClock().nowMicros(),
          sessionId: 'chapter-translation:${keyFor(chapter)}',
          kind: TraceEventKind.comicTranslation,
          payload: {'pageIndex': identity.pageIndex, 'chapterTask': true, ...details},
        )),
      );
      void changed() {
        job.state = task.state.value;
        notifyListeners();
      }
      task.state.addListener(changed);
      try {
        changed();
        if (job.cancelled) await task.cancel();
        await task.completion;
        changed();
      } finally {
        task.state.removeListener(changed);
        await task.close();
        job.task = null;
      }
    } on Object catch (error) {
      job.state = ComicTranslationChapterState(phase: ComicTranslationChapterPhase.failed,
        totalPages: job.state.totalPages, completedPages: job.state.completedPages,
        skippedPages: job.state.skippedPages, pageIndex: job.state.pageIndex, error: error);
    } finally {
      if (job.cancelled) {
        job.state = ComicTranslationChapterState(phase: ComicTranslationChapterPhase.cancelled,
          totalPages: job.state.totalPages, completedPages: job.state.completedPages,
          skippedPages: job.state.skippedPages, pageIndex: job.state.pageIndex);
      }
      notifyListeners();
    }
  }

  Future<void> cancel(String key) async {
    final job = _jobs[key];
    if (job == null || !job.state.isActive) return;
    if (job.cancelled) return job.completion;
    job.cancelled = true;
    job.state = ComicTranslationChapterState(phase: ComicTranslationChapterPhase.cancelling,
      totalPages: job.state.totalPages, completedPages: job.state.completedPages,
      skippedPages: job.state.skippedPages, pageIndex: job.state.pageIndex);
    notifyListeners();
    job.cancellation.complete();
    await job.task?.cancel();
    await job.completion;
  }

  Future<void> cancelAll() => Future.wait([
    for (final key in _jobs.keys.toList()) cancel(key),
  ]);
}

final class _ChapterJob {
  _ChapterJob(int totalPages) : state = ComicTranslationChapterState(
    phase: ComicTranslationChapterPhase.running, totalPages: totalPages,
    pagePhase: ComicTranslationPhase.waitingForImage,
  );
  ComicTranslationChapterState state;
  final cancellation = Completer<void>();
  late Future<void> completion;
  ComicTranslationChapterTask? task;
  bool cancelled = false;
}
