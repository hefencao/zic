import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';

import 'chapter_downloads.dart';

enum WholeComicQueuePhase {
  queued,
  running,
  waitingForPolicy,
  requiresUserAction,
  paused,
  complete,
  failed,
  cancelled,
}

enum WholeComicQueueUserActionKind { resolveDownloadPlacement }

final class WholeComicQueueUserAction {
  const WholeComicQueueUserAction({
    required this.kind,
    required this.message,
    required this.chapterId,
    required this.chapterTitle,
    this.directory,
    this.existingOwnerKey,
    this.requestOwnerKey,
  });

  final WholeComicQueueUserActionKind kind;
  final String message;
  final String chapterId;
  final String chapterTitle;
  final String? directory;
  final String? existingOwnerKey;
  final String? requestOwnerKey;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'message': message,
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'directory': directory,
        'existingOwnerKey': existingOwnerKey,
        'requestOwnerKey': requestOwnerKey,
      };

  factory WholeComicQueueUserAction.fromJson(Map<String, Object?> json) =>
      WholeComicQueueUserAction(
        kind: _enumByName(
          WholeComicQueueUserActionKind.values,
          json['kind'],
          WholeComicQueueUserActionKind.resolveDownloadPlacement,
        ),
        message: _requiredString(json, 'message'),
        chapterId: _requiredString(json, 'chapterId'),
        chapterTitle: _requiredString(json, 'chapterTitle'),
        directory: json['directory'] as String?,
        existingOwnerKey: json['existingOwnerKey'] as String?,
        requestOwnerKey: json['requestOwnerKey'] as String?,
      );
}

enum WholeComicNetworkPolicy { any, unmetered }

enum WholeComicPowerPolicy { any, charging }

final class WholeComicQueuePolicy {
  const WholeComicQueuePolicy({
    this.concurrency = 1,
    this.network = WholeComicNetworkPolicy.any,
    this.power = WholeComicPowerPolicy.any,
  }) : assert(concurrency >= 1 && concurrency <= 4);

  final int concurrency;
  final WholeComicNetworkPolicy network;
  final WholeComicPowerPolicy power;

  WholeComicQueuePolicy copyWith({
    int? concurrency,
    WholeComicNetworkPolicy? network,
    WholeComicPowerPolicy? power,
  }) =>
      WholeComicQueuePolicy(
        concurrency: concurrency ?? this.concurrency,
        network: network ?? this.network,
        power: power ?? this.power,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'concurrency': concurrency,
        'network': network.name,
        'power': power.name,
      };

  factory WholeComicQueuePolicy.fromJson(Map<String, Object?> json) {
    final rawConcurrency = json['concurrency'];
    final concurrency = rawConcurrency is int ? rawConcurrency.clamp(1, 4) : 1;
    return WholeComicQueuePolicy(
      concurrency: concurrency,
      network: _enumByName(
        WholeComicNetworkPolicy.values,
        json['network'],
        WholeComicNetworkPolicy.any,
      ),
      power: _enumByName(
        WholeComicPowerPolicy.values,
        json['power'],
        WholeComicPowerPolicy.any,
      ),
    );
  }
}

final class WholeComicQueueEnvironment {
  const WholeComicQueueEnvironment({
    required this.networkAvailable,
    required this.unmetered,
    required this.charging,
  });

  const WholeComicQueueEnvironment.assumedAvailable()
      : networkAvailable = true,
        unmetered = true,
        charging = true;

  final bool networkAvailable;
  final bool unmetered;
  final bool charging;
}

abstract interface class WholeComicQueueEnvironmentSource {
  WholeComicQueueEnvironment get current;
  Stream<WholeComicQueueEnvironment> get changes;
  Future<void> close();
}

final class StaticWholeComicQueueEnvironment
    implements WholeComicQueueEnvironmentSource {
  const StaticWholeComicQueueEnvironment([
    this.current = const WholeComicQueueEnvironment.assumedAvailable(),
  ]);

  @override
  final WholeComicQueueEnvironment current;

  @override
  Stream<WholeComicQueueEnvironment> get changes =>
      const Stream<WholeComicQueueEnvironment>.empty();

  @override
  Future<void> close() async {}
}

final class MutableWholeComicQueueEnvironment
    implements WholeComicQueueEnvironmentSource {
  MutableWholeComicQueueEnvironment(this._current);

  WholeComicQueueEnvironment _current;
  final StreamController<WholeComicQueueEnvironment> _changes =
      StreamController<WholeComicQueueEnvironment>.broadcast(sync: true);

  @override
  WholeComicQueueEnvironment get current => _current;

  @override
  Stream<WholeComicQueueEnvironment> get changes => _changes.stream;

  void update(WholeComicQueueEnvironment value) {
    _current = value;
    if (!_changes.isClosed) {
      _changes.add(value);
    }
  }

  @override
  Future<void> close() =>
      _changes.isClosed ? Future<void>.value() : _changes.close();
}

final class WholeComicQueueJobSnapshot {
  const WholeComicQueueJobSnapshot({
    required this.jobId,
    required this.sourceId,
    required this.comicId,
    required this.comicTitle,
    required this.phase,
    required this.completedChapters,
    required this.totalChapters,
    required this.completedPageUnits,
    required this.totalPages,
    required this.activeChapterTitles,
    required this.createdAt,
    required this.updatedAt,
    this.failure,
    this.userAction,
  });

  final String jobId;
  final String sourceId;
  final String comicId;
  final String comicTitle;
  final WholeComicQueuePhase phase;
  final int completedChapters;
  final int totalChapters;
  final double completedPageUnits;
  final int totalPages;
  final List<String> activeChapterTitles;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? failure;
  final WholeComicQueueUserAction? userAction;

  String get comicIdentity => comicLibraryIdentity(sourceId, comicId);
  bool get isActive => phase == WholeComicQueuePhase.running;
  bool get canPause =>
      phase == WholeComicQueuePhase.running ||
      phase == WholeComicQueuePhase.queued ||
      phase == WholeComicQueuePhase.waitingForPolicy;
  bool get canResume => phase == WholeComicQueuePhase.paused;
  bool get canRetry =>
      phase == WholeComicQueuePhase.failed ||
      phase == WholeComicQueuePhase.cancelled;
  bool get requiresUserAction =>
      phase == WholeComicQueuePhase.requiresUserAction && userAction != null;
  bool get hasPendingWork =>
      phase == WholeComicQueuePhase.queued ||
      phase == WholeComicQueuePhase.running ||
      phase == WholeComicQueuePhase.waitingForPolicy ||
      phase == WholeComicQueuePhase.paused;

  int get completedPages => completedPageUnits.floor();

  double get fraction => totalPages == 0
      ? 0
      : (completedPageUnits / totalPages).clamp(0, 1).toDouble();
}

final class WholeComicQueueSnapshot {
  const WholeComicQueueSnapshot({
    required this.policy,
    required this.environment,
    required this.jobs,
  });

  final WholeComicQueuePolicy policy;
  final WholeComicQueueEnvironment environment;
  final List<WholeComicQueueJobSnapshot> jobs;

  WholeComicQueueJobSnapshot? jobFor(String sourceId, String comicId) {
    final identity = comicLibraryIdentity(sourceId, comicId);
    for (final job in jobs) {
      if (job.comicIdentity == identity) {
        return job;
      }
    }
    return null;
  }
}

abstract interface class WholeComicQueueStore {
  Future<Map<String, Object?>?> load();
  Future<void> save(Map<String, Object?> data);
  Future<void> close();
}

final class MemoryWholeComicQueueStore implements WholeComicQueueStore {
  Map<String, Object?>? _value;

  @override
  Future<Map<String, Object?>?> load() async => _value == null
      ? null
      : (jsonDecode(jsonEncode(_value)) as Map<Object?, Object?>)
          .cast<String, Object?>();

  @override
  Future<void> save(Map<String, Object?> data) async {
    _value = (jsonDecode(jsonEncode(data)) as Map<Object?, Object?>)
        .cast<String, Object?>();
  }

  @override
  Future<void> close() async {}
}

final class WholeComicDownloadQueue {
  WholeComicDownloadQueue({
    required ChapterDownloadService downloads,
    WholeComicQueueStore? store,
    WholeComicQueueEnvironmentSource? environment,
    bool ownsEnvironment = false,
    String? storageRootId,
  })  : _downloads = downloads,
        _storageRootId = storageRootId ?? 'default',
        _store = store ?? MemoryWholeComicQueueStore(),
        _environment = environment ?? const StaticWholeComicQueueEnvironment(),
        _ownsEnvironment = environment == null || ownsEnvironment {
    _ready = _restore();
    _downloadSubscription = _downloads.changes.listen(
      _acceptChapterSnapshot,
      onError: (Object _, StackTrace __) {},
    );
    _environmentSubscription = _environment.changes.listen(
      (_) {
        _emit();
        _requestSchedule();
      },
      onError: (Object _, StackTrace __) {
        // Keep the last trusted snapshot. A platform signal channel failure
        // must not crash the download scheduler or silently relax policy.
      },
    );
  }



  final ChapterDownloadService _downloads;
  final WholeComicQueueStore _store;
  /// Queue completion is scoped to the physical download authority. A root or
  /// SAF tree change forces completed jobs back through reconciliation instead
  /// of presenting bytes from the previous store as complete.
  final String _storageRootId;
  final WholeComicQueueEnvironmentSource _environment;
  final bool _ownsEnvironment;
  final StreamController<WholeComicQueueSnapshot> _changes =
      StreamController<WholeComicQueueSnapshot>.broadcast(sync: true);
  final Map<String, _WholeComicQueueJob> _jobs =
      <String, _WholeComicQueueJob>{};
  final Map<String, _ActiveQueueChapter> _active =
      <String, _ActiveQueueChapter>{};
  final Map<String, ChapterDownloadSnapshot> _chapterSnapshots =
      <String, ChapterDownloadSnapshot>{};

  late final Future<void> _ready;
  late final StreamSubscription<ChapterDownloadSnapshot>
      _downloadSubscription;
  late final StreamSubscription<WholeComicQueueEnvironment>
      _environmentSubscription;
  WholeComicQueuePolicy _policy = const WholeComicQueuePolicy();
  Future<void> _persistTail = Future<void>.value();
  bool _scheduleRequested = false;
  bool _scheduling = false;
  bool _closed = false;
  bool _closing = false;

  Future<void> get ready => _ready;
  Stream<WholeComicQueueSnapshot> get changes => _changes.stream;
  WholeComicQueueSnapshot get snapshot => _snapshot();

  void _acceptChapterSnapshot(ChapterDownloadSnapshot snapshot) {
    if (_closed || _closing) return;
    final covered = _jobs.values.any(
      (job) => job.chapters.any(
        (entry) => _chapterIdentity(entry) == snapshot.identity,
      ),
    );
    if (!covered) return;
    _chapterSnapshots[snapshot.identity] = snapshot;
    _emit();
  }

  Future<void> enqueue({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    required Iterable<ImportedLibraryEntry> chapters,
    String? placementDirectory,
    DownloadPlacementMode? placementMode,
    String? observedOwnerKey,
  }) async {
    await ready;
    _requireOpen();
    final entries = <ImportedLibraryEntry>[];
    final identities = <String>{};
    for (final entry in chapters) {
      if (entry.chapter.sourceId != sourceId ||
          entry.chapter.comicId != comicId) {
        throw ArgumentError('whole-comic queue chapters must share ownership');
      }
      if (identities.add(_chapterIdentity(entry))) {
        entries.add(entry.copyWith(clearProgress: true));
      }
    }
    if (entries.isEmpty) {
      throw ArgumentError.value(chapters, 'chapters', 'must not be empty');
    }
    entries.sort((left, right) {
      final sequence = left.chapter.sequence.compareTo(right.chapter.sequence);
      return sequence != 0
          ? sequence
          : left.chapter.displayName.compareTo(right.chapter.displayName);
    });
    final jobId = comicLibraryIdentity(sourceId, comicId);
    final existing = _jobs[jobId];
    if (existing != null &&
        (existing.phase == WholeComicQueuePhase.queued ||
            existing.phase == WholeComicQueuePhase.running ||
            existing.phase == WholeComicQueuePhase.waitingForPolicy ||
            existing.phase == WholeComicQueuePhase.paused)) {
      await _refreshCompleted(existing);
      existing.touch();
      await _publish();
      _requestSchedule();
      return;
    }
    final now = DateTime.now().toUtc();
    final replacesPlacement =
        placementDirectory != null || placementMode != null;
    final effectivePlacementMode = replacesPlacement
        ? placementMode ?? DownloadPlacementMode.createNew
        : existing?.placementMode;
    final effectiveObservedOwnerKey = replacesPlacement
        ? observedOwnerKey
        : existing?.observedOwnerKey;
    if (effectivePlacementMode == DownloadPlacementMode.overwrite &&
        effectiveObservedOwnerKey != null &&
        effectiveObservedOwnerKey.contains('\u0000')) {
      final parts = effectiveObservedOwnerKey.split('\u0000');
      if (parts.length == 2) {
        final displacedJobId = comicLibraryIdentity(parts[0], parts[1]);
        if (displacedJobId != jobId && _jobs.containsKey(displacedJobId)) {
          final displaced = _jobs[displacedJobId]!;
          displaced.phase = WholeComicQueuePhase.cancelled;
          displaced.touch();
          await _cancelActiveForJob(displacedJobId);
          _jobs.remove(displacedJobId);
        }
      }
    }
    final job = _WholeComicQueueJob(
      jobId: jobId,
      sourceId: sourceId,
      comicId: comicId,
      comicTitle: comicTitle,
      chapters: entries,
      completedChapterIdentities:
          existing?.completedChapterIdentities ?? <String>{},
      phase: WholeComicQueuePhase.queued,
      failure: null,
      userAction: null,
      placementDirectory: replacesPlacement
          ? placementDirectory
          : existing?.placementDirectory,
      placementMode: effectivePlacementMode ?? DownloadPlacementMode.createNew,
      observedOwnerKey: effectiveObservedOwnerKey,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    _jobs[jobId] = job;
    await _refreshCompleted(job);
    if (job.completedChapterIdentities.length == job.chapters.length) {
      job.phase = WholeComicQueuePhase.complete;
    }
    await _publish();
    _requestSchedule();
  }

  /// The queue job covering this chapter (any phase), for the unified
  /// existing-download lookup; null when no job covers it.
  WholeComicQueueJobSnapshot? jobForChapter({
    required String sourceId,
    required String comicId,
    required String chapterId,
  }) {
    for (final job in _jobs.values) {
      final contains = job.chapters.any(
        (entry) =>
            entry.chapter.sourceId == sourceId &&
            entry.chapter.comicId == comicId &&
            entry.chapter.chapterId == chapterId,
      );
      if (!contains) continue;
      return job.snapshot(
        active: const <String>[],
        chapterSnapshots: _chapterSnapshots,
      );
    }
    return null;
  }

  Future<void> pause(String jobId) async {
    await ready;
    final job = _requireJob(jobId);
    if (job.phase == WholeComicQueuePhase.complete ||
        job.phase == WholeComicQueuePhase.cancelled ||
        job.phase == WholeComicQueuePhase.requiresUserAction) {
      return;
    }
    job.phase = WholeComicQueuePhase.paused;
    job.failure = null;
    job.userAction = null;
    job.touch();
    await _publish();
    await _cancelActiveForJob(jobId);
  }

  Future<void> resume(String jobId) async {
    await ready;
    final job = _requireJob(jobId);
    if (job.phase != WholeComicQueuePhase.paused &&
        job.phase != WholeComicQueuePhase.waitingForPolicy) {
      return;
    }
    job.phase = WholeComicQueuePhase.queued;
    job.failure = null;
    job.userAction = null;
    job.touch();
    await _publish();
    _requestSchedule();
  }

  /// Optional source-side refresher used to self-heal chapters whose
  /// persisted page URIs died with a plugin runtime restart. The owner
  /// (Home) binds it after construction; the queue itself never reaches into
  /// sources.
  Future<ImportedLibraryEntry?> Function(ImportedLibraryEntry entry)?
      refreshStaleChapter;

  Future<void> retry(String jobId) async {
    await ready;
    final job = _requireJob(jobId);
    if (job.phase != WholeComicQueuePhase.failed &&
        job.phase != WholeComicQueuePhase.cancelled) {
      return;
    }
    await _refreshCompleted(job);
    job.failedChapterIdentities.clear();
    job.phase = job.completedChapterIdentities.length == job.chapters.length
        ? WholeComicQueuePhase.complete
        : WholeComicQueuePhase.queued;
    job.failure = null;
    job.userAction = null;
    job.touch();
    await _publish();
    _requestSchedule();
  }

  Future<void> cancel(String jobId) async {
    await ready;
    final job = _requireJob(jobId);
    if (job.phase == WholeComicQueuePhase.complete ||
        job.phase == WholeComicQueuePhase.cancelled) {
      return;
    }
    job.phase = WholeComicQueuePhase.cancelled;
    job.failure = null;
    job.userAction = null;
    job.touch();
    await _publish();
    await _cancelActiveForJob(jobId);
  }

  Future<void> remove(String jobId) async {
    await ready;
    final job = _requireJob(jobId);
    job.phase = WholeComicQueuePhase.cancelled;
    job.touch();
    await _publish();
    await _cancelActiveForJob(jobId);
    _jobs.remove(jobId);
    await _publish();
  }

  Future<void> updatePolicy(WholeComicQueuePolicy policy) async {
    await ready;
    _requireOpen();
    _policy = policy;
    for (final job in _jobs.values) {
      if (job.phase == WholeComicQueuePhase.waitingForPolicy) {
        job.phase = WholeComicQueuePhase.queued;
        job.touch();
      }
    }
    await _publish();
    _requestSchedule();
  }

  Future<void> close() async {
    if (_closed || _closing) {
      return;
    }
    await ready;
    _closing = true;
    for (final job in _jobs.values) {
      if (job.phase == WholeComicQueuePhase.running) {
        job.phase = WholeComicQueuePhase.queued;
        job.touch();
      }
    }
    await _cancelAllActive();
    if (!_closed) {
      await _publish();
    }
    try {
      await _persistTail.timeout(const Duration(seconds: 10));
    } on Object {
      // A broken persistence sink must not make application teardown
      // unbounded; the last successfully committed queue document remains
      // authoritative for the next launch.
    }
    await _downloadSubscription.cancel();
    await _environmentSubscription.cancel();
    if (_ownsEnvironment) {
      await _environment.close();
    }
    await _store.close();
    _closed = true;
    _closing = false;
    await _changes.close();
  }

  Future<void> _restore() async {
    final data = await _store.load();
    var changed = false;
    final persistedRoot = data?['storageRootId'];
    final rootChanged = data != null &&
        ((persistedRoot is String && persistedRoot != _storageRootId) ||
            (persistedRoot == null && _storageRootId != 'default'));
    if (rootChanged) changed = true;
    if (data != null) {
      final rawPolicy = data['policy'];
      if (rawPolicy is Map<Object?, Object?>) {
        _policy = WholeComicQueuePolicy.fromJson(
          rawPolicy.cast<String, Object?>(),
        );
      }
      final rawJobs = data['jobs'];
      if (rawJobs is List<Object?>) {
        for (final rawJob in rawJobs) {
          if (rawJob is! Map<Object?, Object?>) {
            changed = true;
            continue;
          }
          final _WholeComicQueueJob job;
          try {
            job = _WholeComicQueueJob.fromJson(
              rawJob.cast<String, Object?>(),
            );
          } on Object {
            // Preserve a valid queue file even when one old job was malformed;
            // the malformed record is quarantined by the JSON store on the
            // next write instead of producing a restore/schedule hot loop.
            changed = true;
            continue;
          }
          if (job.phase == WholeComicQueuePhase.running) {
            job.phase = WholeComicQueuePhase.queued;
            changed = true;
          }
          if (rootChanged && job.phase == WholeComicQueuePhase.complete) {
            job.phase = WholeComicQueuePhase.queued;
            job.completedChapterIdentities.clear();
            job.failure = null;
            changed = true;
          }
          _jobs[job.jobId] = job;
        }
      }
    }
    for (final job in _jobs.values) {
      // Terminal queue phases are already durable user intent. Re-scanning
      // every chapter of a completed/failed/cancelled comic during cold start
      // can block the Flutter isolate for hundreds of milliseconds. Explicit
      // retry or re-enqueue still calls _refreshCompleted before scheduling;
      // startup only needs the persisted terminal projection.
      if (job.phase == WholeComicQueuePhase.complete) {
        job.completedChapterIdentities
          ..clear()
          ..addAll(job.chapters.map(_chapterIdentity));
        continue;
      }
      if (job.phase == WholeComicQueuePhase.failed ||
          job.phase == WholeComicQueuePhase.cancelled ||
          job.phase == WholeComicQueuePhase.requiresUserAction) {
        continue;
      }
      final completedBefore = Set<String>.of(job.completedChapterIdentities);
      final phaseBefore = job.phase;
      final failureBefore = job.failure;
      await _refreshCompleted(job);
      if (completedBefore.length != job.completedChapterIdentities.length ||
          !completedBefore.containsAll(job.completedChapterIdentities)) {
        changed = true;
      }
      if (job.completedChapterIdentities.length == job.chapters.length) {
        job.phase = WholeComicQueuePhase.complete;
        job.failure = null;
      }
      changed = changed ||
          phaseBefore != job.phase ||
          failureBefore != job.failure;
    }
    if (data == null) {
      // An empty install has no queue state to restore. Avoid creating and
      // flushing a default JSON document on the first Home startup; the first
      // explicit queue mutation will persist the complete state.
    } else if (changed) {
      await _publish();
    } else {
      // Preserve the initial snapshot notification for callers that supplied
      // a durable queue, without rewriting an unchanged file on every launch.
      _emit();
    }
    _requestSchedule();
  }

  bool _policyAllowsWork() {
    final current = _environment.current;
    if (!current.networkAvailable) {
      return false;
    }
    if (_policy.network == WholeComicNetworkPolicy.unmetered &&
        !current.unmetered) {
      return false;
    }
    if (_policy.power == WholeComicPowerPolicy.charging && !current.charging) {
      return false;
    }
    return true;
  }

  void _requestSchedule() {
    if (_closed || _closing || _scheduleRequested) {
      return;
    }
    _scheduleRequested = true;
    scheduleMicrotask(_schedule);
  }

  Future<void> _schedule() async {
    if (_scheduling || _closed || _closing) {
      return;
    }
    _scheduling = true;
    _scheduleRequested = false;
    try {
      await ready;
      var changed = false;
      final allowed = _policyAllowsWork();
      final policySuspendedJobs = <String>[];
      for (final job in _orderedJobs()) {
        if (job.phase == WholeComicQueuePhase.complete ||
            job.phase == WholeComicQueuePhase.failed ||
            job.phase == WholeComicQueuePhase.cancelled ||
            job.phase == WholeComicQueuePhase.requiresUserAction ||
            job.phase == WholeComicQueuePhase.paused) {
          continue;
        }
        if (!allowed) {
          if (job.phase != WholeComicQueuePhase.waitingForPolicy) {
            job.phase = WholeComicQueuePhase.waitingForPolicy;
            job.touch();
            changed = true;
          }
          if (_hasActiveForJob(job.jobId)) {
            policySuspendedJobs.add(job.jobId);
          }
          continue;
        }
        if (job.phase == WholeComicQueuePhase.waitingForPolicy ||
            job.phase == WholeComicQueuePhase.queued) {
          job.phase = WholeComicQueuePhase.running;
          job.touch();
          changed = true;
        }
      }
      while (allowed && _active.length < _policy.concurrency) {
        final next = _nextRunnableChapter();
        if (next == null) {
          break;
        }
        _launch(next.$1, next.$2);
        changed = true;
      }
      for (final job in _jobs.values) {
        if (job.phase == WholeComicQueuePhase.running &&
            !_hasActiveForJob(job.jobId) &&
            job.completedChapterIdentities.length +
                    job.failedChapterIdentities.length ==
                job.chapters.length) {
          final failures = job.failedChapterIdentities.length;
          job.phase = failures > 0
              ? WholeComicQueuePhase.failed
              : WholeComicQueuePhase.complete;
          job.failure = failures > 0
              ? '$failures/${job.chapters.length} 章下载失败，可重试'
              : null;
          job.touch();
          changed = true;
        }
      }
      if (changed) {
        await _publish();
      }
      for (final jobId in policySuspendedJobs) {
        await _cancelActiveForJob(jobId);
      }
    } finally {
      _scheduling = false;
      if (_scheduleRequested) {
        _scheduleRequested = false;
        _requestSchedule();
      }
    }
  }

  List<_WholeComicQueueJob> _orderedJobs() {
    final jobs = _jobs.values.toList(growable: false);
    jobs.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return jobs;
  }

  (_WholeComicQueueJob, ImportedLibraryEntry)? _nextRunnableChapter() {
    for (final job in _orderedJobs()) {
      if (job.phase != WholeComicQueuePhase.running) {
        continue;
      }
      for (final entry in job.chapters) {
        final identity = _chapterIdentity(entry);
        if (job.completedChapterIdentities.contains(identity) ||
            job.failedChapterIdentities.contains(identity) ||
            _active.containsKey(identity)) {
          continue;
        }
        return (job, entry);
      }
    }
    return null;
  }

  void _launch(_WholeComicQueueJob job, ImportedLibraryEntry entry) {
    final identity = _chapterIdentity(entry);
    final run = _runChapter(job, entry);
    _active[identity] = _ActiveQueueChapter(
      jobId: job.jobId,
      entry: entry,
      run: run,
    );
    unawaited(run);
  }

  Future<void> _runChapter(
    _WholeComicQueueJob job,
    ImportedLibraryEntry entry,
  ) async {
    final identity = _chapterIdentity(entry);
    Object? chapterFailure;
    try {
      if (job.placementDirectory != null && job.placementDirectory!.isNotEmpty) {
        await _downloads.claimComicDirectory(
          sourceId: job.sourceId,
          comicId: job.comicId,
          comicTitle: job.comicTitle,
          directoryName: job.placementDirectory!,
          mode: job.placementMode ?? DownloadPlacementMode.createNew,
          observedOwnerKey: job.observedOwnerKey,
        );
        // The queue waits for the placement transaction before it starts any
        // page transfer. This closes the conflict-decision to write boundary
        // and surfaces a failed SQLite commit as a job failure.
        final claimed = await _downloads.getDownloadPlacement(
          sourceId: job.sourceId,
          comicId: job.comicId,
        );
        if (claimed == null) {
          throw StateError('download placement claim was not persisted');
        }
      }
      final current = await _downloads.inspect(entry);
      if (!current.isComplete) {
        await _downloads.download(entry);
      }
      final next = await _downloads.inspect(entry);
      if (next.isComplete) {
        job.completedChapterIdentities.add(identity);
        job.failedChapterIdentities.remove(identity);
      } else if (next.failure != null) {
        chapterFailure = next.failure!;
      }
    } on Object catch (error) {
      if (!_closing && job.phase == WholeComicQueuePhase.running) {
        chapterFailure = error;
      }
    }
    if (chapterFailure != null &&
        !_closing &&
        job.phase == WholeComicQueuePhase.running) {
      final userAction = _queueUserActionFor(chapterFailure, entry);
      if (userAction != null) {
        job.phase = WholeComicQueuePhase.requiresUserAction;
        job.userAction = userAction;
        job.failure = userAction.message;
        job.failedChapterIdentities.remove(identity);
        _active.remove(identity);
        job.touch();
        await _publish();
        await _cancelActiveForJob(job.jobId);
        _requestSchedule();
        return;
      }
      // One stale-manifest self-heal per chapter per session: a plugin
      // runtime restart invalidates persisted page URIs, and re-pulling the
      // chapter manifest from the source restores fresh ones.
      if (await _selfHealStaleChapter(job, entry, chapterFailure)) {
        _active.remove(identity);
        _requestSchedule();
        return;
      }
      // Chapter-scoped failure: never cancel sibling chapters. The job only
      // turns failed once every chapter reached a terminal state (see the
      // completion check in _schedule).
      job.failedChapterIdentities.add(identity);
      job.userAction = null;
      job.failure =
          '章节「${entry.chapter.displayName}」下载失败：${_describeChapterFailure(chapterFailure)}';
    }
    _active.remove(identity);
    if (_closing || _closed) return;
    job.touch();
    await _publish();
    _requestSchedule();
  }

  /// Returns true when a refreshed manifest was obtained and the chapter was
  /// relaunched; false leaves failure bookkeeping to the caller.
  Future<bool> _selfHealStaleChapter(
    _WholeComicQueueJob job,
    ImportedLibraryEntry entry,
    Object error,
  ) async {
    if (!error.toString().contains('must use a runtime token')) {
      return false;
    }
    if (refreshStaleChapter == null) {
      return false;
    }
    final identity = _chapterIdentity(entry);
    if (!job.selfHealAttemptedIdentities.add(identity)) {
      return false;
    }
    final ImportedLibraryEntry? refreshed;
    try {
      refreshed = await refreshStaleChapter!(entry);
    } on Object {
      return false;
    }
    if (refreshed == null || _closing) {
      return false;
    }
    final index = job.chapters.indexWhere(
      (candidate) => _chapterIdentity(candidate) == identity,
    );
    if (index >= 0) {
      job.chapters[index] = refreshed;
    }
    job.completedChapterIdentities.remove(identity);
    job.failedChapterIdentities.remove(identity);
    _launch(job, refreshed);
    return true;
  }

  Future<void> _refreshCompleted(_WholeComicQueueJob job) async {
    final completed = <String>{};
    try {
      // Restore is a startup path and a whole-comic job can contain hundreds
      // of chapters. Persistent chapter downloads already expose a bulk
      // projection backed by one artifact index read; avoid reopening and
      // scanning the same index once per chapter here.
      for (final snapshot in await _downloads.inspectMany(job.chapters)) {
        _chapterSnapshots[snapshot.identity] = snapshot;
        if (snapshot.isComplete) {
          completed.add(snapshot.identity);
        }
      }
    } on Object {
      // Preserve per-entry recovery for a stale diagnostic record or an older
      // service implementation whose bulk projection cannot complete.
      for (final entry in job.chapters) {
        try {
          final snapshot = await _downloads.inspect(entry);
          _chapterSnapshots[snapshot.identity] = snapshot;
          if (snapshot.isComplete) {
            completed.add(_chapterIdentity(entry));
          }
        } on Object {
          // Missing/stale artifacts remain queued and are redownloaded.
        }
      }
    }
    job.completedChapterIdentities
      ..clear()
      ..addAll(completed);
  }

  Future<void> _cancelActiveForJob(String jobId) async {
    final active = _active.values
        .where((item) => item.jobId == jobId)
        .toList(growable: false);
    await Future.wait<void>(
      active.map((item) async {
        try {
          await _downloads.cancel(item.entry).timeout(
            const Duration(seconds: 10),
          );
        } on Object {
          // Keep the queue command bounded even if a source bridge is stuck.
        }
        try {
          await item.run.timeout(const Duration(seconds: 10));
        } on Object {
          // Cancellation is bounded. The chapter task remains authoritative
          // and will remove its active entry when its own transport exits.
        }
      }),
    );
  }

  Future<void> _cancelAllActive() async {
    final active = _active.values.toList(growable: false);
    await Future.wait<void>(
      active.map((item) async {
        try {
          await _downloads.cancel(item.entry).timeout(
            const Duration(seconds: 10),
          );
        } on Object {
          // Closing must not wait forever on a broken source bridge.
        }
        try {
          await item.run.timeout(const Duration(seconds: 10));
        } on Object {
          // Closing resumes the whole-comic job on the next launch.
        }
      }),
    );
  }

  bool _hasActiveForJob(String jobId) =>
      _active.values.any((item) => item.jobId == jobId);

  _WholeComicQueueJob _requireJob(String jobId) {
    _requireOpen();
    final job = _jobs[jobId];
    if (job == null) {
      throw StateError('whole-comic queue job does not exist: $jobId');
    }
    return job;
  }

  void _requireOpen() {
    if (_closed || _closing) {
      throw StateError('whole-comic download queue is closed');
    }
  }

  WholeComicQueueSnapshot _snapshot() {
    final jobs = _orderedJobs()
        .map(
          (job) => job.snapshot(
            active: _active.values
                .where((item) => item.jobId == job.jobId)
                .map((item) => item.entry.chapter.displayName),
            chapterSnapshots: _chapterSnapshots,
          ),
        )
        .toList(growable: false);
    return WholeComicQueueSnapshot(
      policy: _policy,
      environment: _environment.current,
      jobs: List<WholeComicQueueJobSnapshot>.unmodifiable(jobs),
    );
  }

  void _emit() {
    if (!_changes.isClosed) {
      _changes.add(_snapshot());
    }
  }

  Future<void> _publish() async {
    _emit();
    final data = <String, Object?>{
      'schema': 3,
      'storageRootId': _storageRootId,
      'policy': _policy.toJson(),
      'jobs': _orderedJobs().map((job) => job.toJson()).toList(growable: false),
    };
    final next = _persistTail.then(
      (_) => _store.save(data),
      onError: (_, __) => _store.save(data),
    );
    _persistTail = next;
    await next;
  }
}

final class _ActiveQueueChapter {
  const _ActiveQueueChapter({
    required this.jobId,
    required this.entry,
    required this.run,
  });

  final String jobId;
  final ImportedLibraryEntry entry;
  final Future<void> run;
}

final class _WholeComicQueueJob {
  _WholeComicQueueJob({
    required this.jobId,
    required this.sourceId,
    required this.comicId,
    required this.comicTitle,
    required this.chapters,
    required this.completedChapterIdentities,
    required this.phase,
    required this.createdAt,
    required this.updatedAt,
    this.failure,
    this.userAction,
    this.placementDirectory,
    this.placementMode,
    this.observedOwnerKey,
  });

  final String jobId;
  final String sourceId;
  final String comicId;
  final String comicTitle;
  List<ImportedLibraryEntry> chapters;
  final Set<String> completedChapterIdentities;

  /// Chapters that exhausted their attempts in this session. They stop being
  /// scheduled immediately but never cancel sibling chapters; retry clears
  /// the set so every failed chapter runs again.
  final Set<String> failedChapterIdentities = <String>{};

  /// Chapters that already consumed the one-shot stale-manifest self-heal.
  final Set<String> selfHealAttemptedIdentities = <String>{};
  WholeComicQueuePhase phase;
  String? failure;
  WholeComicQueueUserAction? userAction;
  final String? placementDirectory;
  final DownloadPlacementMode? placementMode;
  final String? observedOwnerKey;
  final DateTime createdAt;
  DateTime updatedAt;

  void touch() => updatedAt = DateTime.now().toUtc();

  WholeComicQueueJobSnapshot snapshot({
    required Iterable<String> active,
    required Map<String, ChapterDownloadSnapshot> chapterSnapshots,
  }) {
    var totalPages = 0;
    var completedPageUnits = 0.0;
    for (final entry in chapters) {
      final pageCount = entry.chapter.pages.length;
      totalPages += pageCount;
      final identity = _chapterIdentity(entry);
      final chapter = chapterSnapshots[identity];
      if (chapter != null) {
        completedPageUnits += chapter.completedPageUnits
            .clamp(0, pageCount)
            .toDouble();
      } else if (completedChapterIdentities.contains(identity)) {
        completedPageUnits += pageCount;
      }
    }
    return WholeComicQueueJobSnapshot(
        jobId: jobId,
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle,
        phase: phase,
        completedChapters: completedChapterIdentities.length,
        totalChapters: chapters.length,
        completedPageUnits: completedPageUnits,
        totalPages: totalPages,
        activeChapterTitles: List<String>.unmodifiable(active),
        createdAt: createdAt,
        updatedAt: updatedAt,
        failure: failure,
        userAction: userAction,
      );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'jobId': jobId,
        'sourceId': sourceId,
        'comicId': comicId,
        'comicTitle': comicTitle,
        'phase': phase.name,
        'failure': failure,
        'userAction': userAction?.toJson(),
        'placementDirectory': placementDirectory,
        'placementMode': placementMode?.name,
        'observedOwnerKey': observedOwnerKey,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'completedChapterIdentities':
            completedChapterIdentities.toList(growable: false),
        'failedChapterIdentities':
            failedChapterIdentities.toList(growable: false),
        'chapters': chapters
            .map((entry) => entry.chapter.toJson())
            .toList(growable: false),
      };

  factory _WholeComicQueueJob.fromJson(Map<String, Object?> json) {
    final rawChapters = json['chapters'];
    if (rawChapters is! List<Object?> || rawChapters.isEmpty) {
      throw const FormatException('whole-comic queue chapters must be a list');
    }
    final chapters = rawChapters.map((value) {
      if (value is! Map<Object?, Object?>) {
        throw const FormatException('whole-comic queue chapter is invalid');
      }
      return ImportedLibraryEntry(
        chapter: ImportedChapterRecord.fromJson(
          value.cast<String, Object?>(),
        ),
      );
    }).toList(growable: false);
    final rawCompleted = json['completedChapterIdentities'];
    final rawUserAction = json['userAction'];
    final userAction = rawUserAction is Map<Object?, Object?>
        ? WholeComicQueueUserAction.fromJson(
            rawUserAction.cast<String, Object?>(),
          )
        : null;
    var phase = _enumByName(
      WholeComicQueuePhase.values,
      json['phase'],
      WholeComicQueuePhase.queued,
    );
    if (phase == WholeComicQueuePhase.requiresUserAction &&
        userAction == null) {
      phase = WholeComicQueuePhase.failed;
    }
    return _WholeComicQueueJob(
      jobId: _requiredString(json, 'jobId'),
      sourceId: _requiredString(json, 'sourceId'),
      comicId: _requiredString(json, 'comicId'),
      comicTitle: _requiredString(json, 'comicTitle'),
      chapters: chapters,
      completedChapterIdentities: rawCompleted is List<Object?>
          ? rawCompleted.whereType<String>().toSet()
          : <String>{},
      phase: phase,
      failure: json['failure'] as String?,
      userAction: userAction,
      placementDirectory: json['placementDirectory'] as String?,
      placementMode: json['placementMode'] == null
          ? null
          : _enumByName(
              DownloadPlacementMode.values,
              json['placementMode'],
              DownloadPlacementMode.createNew,
            ),
      observedOwnerKey: json['observedOwnerKey'] as String?,
      createdAt: DateTime.parse(_requiredString(json, 'createdAt')).toUtc(),
      updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')).toUtc(),
    )
      ..failedChapterIdentities.addAll(
        (json['failedChapterIdentities'] as List<Object?>?)
                ?.whereType<String>() ??
            const <String>[],
      );
  }
}

String _chapterIdentity(ImportedLibraryEntry entry) => chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.comicId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

WholeComicQueueUserAction? _queueUserActionFor(
  Object error,
  ImportedLibraryEntry entry,
) {
  if (error is! Failure || error.code != ErrorCode.policy) {
    return null;
  }
  String? detail(String key) {
    final value = error.details[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  return WholeComicQueueUserAction(
    kind: WholeComicQueueUserActionKind.resolveDownloadPlacement,
    message: error.message,
    chapterId: entry.chapter.chapterId,
    chapterTitle: entry.chapter.displayName,
    directory: detail('directory'),
    existingOwnerKey: detail('existingOwner'),
    requestOwnerKey: detail('requestOwner'),
  );
}

/// Maps raw runtime failures to user-actionable queue messages. A persisted
/// page manifest can outlive the plugin runtime epoch that issued its
/// resource URIs; resuming such a chapter fails hard inside the runtime and
/// only re-downloading from a fresh manifest can recover it.
String _describeChapterFailure(Object error) {
  final text = error.toString();
  if (text.contains('must use a runtime token')) {
    return '页面地址已失效（来源运行时已重启），请删除该任务后重新下载';
  }
  return text;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

T _enumByName<T extends Enum>(
  Iterable<T> values,
  Object? raw,
  T fallback,
) {
  if (raw is String) {
    for (final value in values) {
      if (value.name == raw) {
        return value;
      }
    }
  }
  return fallback;
}
