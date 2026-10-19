import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/widgets.dart';

import 'background_tasks_platform.dart';
import 'download_command_lifetimes.dart';
import 'translation_chapter_jobs.dart';

/// App-scoped read-only task projection. This never schedules page transport
/// or inference; Android actions are forwarded to the original task owners.
final class AppBackgroundTasks {
  AppBackgroundTasks({
    required this.translations,
    BackgroundTasksPlatform? platform,
    ComicTranslationEngineRegistry? engines,
    DownloadCommandLifetimes? commands,
  }) : platform = platform ?? AndroidBackgroundTasksPlatform(),
       engines = engines ?? ComicTranslationEngineRegistry.instance,
       commands = commands ?? DownloadCommandLifetimes.instance {
    this.platform.setActionHandler(_onAction);
    translations.addListener(_changed);
    this.commands.addListener(_changed);
  }

  final AppTranslationChapterJobs translations;
  final BackgroundTasksPlatform platform;
  final ComicTranslationEngineRegistry engines;
  final DownloadCommandLifetimes commands;
  ChapterDownloadService? _downloads;
  WholeComicDownloadQueue? _queue;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Map<String, ChapterDownloadSnapshot> _progress = {};
  Timer? _progressTimer;
  bool _background = false;
  bool _protected = false;
  bool _blocked = false;
  bool _stopping = false;
  bool _closed = false;
  bool _dirty = false;
  Future<void>? _syncing;
  Future<void>? _stoppingWork;
  int _epoch = 0;
  String? _lastShape;

  void bind({ChapterDownloadService? downloads, WholeComicDownloadQueue? queue}) {
    if (identical(_downloads, downloads) && identical(_queue, queue)) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _progress.clear();
    _downloads = downloads;
    _queue = queue;
    if (downloads is ChapterDownloadExecutionSource) {
      _subscriptions.add((downloads as ChapterDownloadExecutionSource)
          .downloadExecutionChanges.listen((_) => _changed()));
    }
    if (downloads != null) {
      _subscriptions.add(downloads.changes.listen((snapshot) {
        if (!_activeDownloads.any((entry) =>
            AppTranslationChapterJobs.keyFor(entry.chapter) == snapshot.identity)) {
          return;
        }
        _progress[snapshot.identity] = snapshot;
        _changed();
      }));
    }
    if (queue != null) {
      _subscriptions.add(queue.changes.listen((_) => _changed()));
    }
    _changed();
  }

  void setLifecycle(AppLifecycleState state) {
    if (_closed) return;
    if (state == AppLifecycleState.resumed) {
      _background = false;
      if (!_stopping) _blocked = false;
    } else if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _background = true;
    } else {
      return;
    }
    unawaited(engines.setBackground(_background));
    _changed(immediate: true);
  }

  List<ImportedLibraryEntry> get _activeDownloads {
    final downloads = _downloads;
    return downloads is ChapterDownloadExecutionSource
        ? (downloads as ChapterDownloadExecutionSource).activeDownloadEntries : const [];
  }

  Map<String, Object> _projection() {
    final entries = _activeDownloads;
    final jobs = _queue?.snapshot.jobs.where((job) => job.canPause).toList() ?? [];
    final chapterStates = translations.activeStates;
    var completed = 0;
    var total = 0;
    for (final entry in entries) {
      final chapter = entry.chapter;
      final id = chapterDownloadIdentity(chapter.sourceId, chapter.comicId,
        chapter.chapterId, chapter.sourceRevision);
      completed += _progress[id]?.completedPages ?? 0;
      total += chapter.pages.length;
    }
    for (final state in chapterStates) {
      completed += state.completedPages;
      total += state.totalPages;
    }
    // No chapter is active while a queue is waiting for Wi-Fi/power. Keep its
    // visible notification, but Android does not hold a CPU lease in that state.
    final waiting = entries.isEmpty && chapterStates.isEmpty && commands.activeCount == 0 && jobs.isNotEmpty;
    return {
      'active': entries.isNotEmpty || jobs.isNotEmpty || chapterStates.isNotEmpty || commands.activeCount > 0,
      'downloads': entries.length,
      'preparing': commands.activeCount,
      'queued': jobs.length,
      'translations': chapterStates.length,
      'completed': completed,
      'total': total,
      'waiting': waiting,
      'stopping': _stopping,
    };
  }

  void _changed({bool immediate = false}) {
    if (_closed) return;
    final projection = _projection();
    // Drop finished chapter projections instead of accumulating the library.
    final activeIds = _activeDownloads.map((entry) => AppTranslationChapterJobs.keyFor(entry.chapter)).toSet();
    _progress.removeWhere((id, _) => !activeIds.contains(id));
    final shape = '${projection['active']}:${projection['downloads']}:'
        '${projection['preparing']}:${projection['queued']}:${projection['translations']}:${projection['stopping']}';
    final changedShape = shape != _lastShape;
    _lastShape = shape;
    if (!platform.supported) return;
    if (immediate || changedShape) {
      _progressTimer?.cancel();
      _progressTimer = null;
      _requestSync();
    } else {
      _progressTimer ??= Timer(const Duration(seconds: 1), () {
        _progressTimer = null;
        _requestSync();
      });
    }
  }

  void _requestSync() {
    if (_closed) return;
    _dirty = true;
    _syncing ??= _sync().whenComplete(() => _syncing = null);
  }

  Future<void> _sync() async {
    while (_dirty && !_closed) {
      _dirty = false;
      final state = _projection();
      if (_blocked) state['active'] = false;
      final epoch = _epoch;
      final protected = await platform.update(state);
      if (_closed || epoch != _epoch) continue;
      _protected = protected && state['active'] == true;
      await engines.setBackgroundWorkAllowed(_protected && translations.hasActive);
    }
  }

  Future<void> _onAction(String action) async {
    if (_closed) return;
    if (action != 'stop' && action != 'timeout' && action != 'interrupted') return;
    if (action != 'stop') {
      _blocked = true;
      _protected = false;
      _epoch++;
      unawaited(engines.setBackgroundWorkAllowed(false));
    }
    await (_stoppingWork ??= _stopWork().whenComplete(() => _stoppingWork = null));
  }

  Future<void> _stopWork() async {
    _stopping = true;
    final preparationDrain = commands.cancelAll();
    _changed(immediate: true);
    try {
      // Pause the queue before cancelling chapters so it cannot replenish the
      // network window. Individual commands keep already committed partials.
      final queue = _queue;
      if (queue != null) {
        try {
          await Future.wait([
            for (final job in queue.snapshot.jobs.where((job) => job.canPause))
              queue.pause(job.jobId),
          ]);
        } on Object catch (error) {
          debugPrint('Pausing background download queue failed: $error');
        }
      }
      await Future.wait([
        preparationDrain,
        translations.cancelAll(),
        for (final entry in _activeDownloads) _downloads!.cancel(entry),
      ]);
    } on Object catch (error) {
      debugPrint('Stopping background tasks failed: $error');
    } finally {
      _stopping = false;
      _changed(immediate: true);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _epoch++;
    translations.removeListener(_changed);
    commands.removeListener(_changed);
    _progressTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _syncing;
    platform.setActionHandler(null);
    await platform.update({'active': false});
    await engines.setBackgroundWorkAllowed(false);
  }
}
