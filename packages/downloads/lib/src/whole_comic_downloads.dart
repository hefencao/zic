import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';

import 'chapter_downloads.dart';

enum WholeComicQueuePhase {
  queued,
  running,
  waitingForPolicy,
  paused,
  complete,
  failed,
  cancelled,
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
    required this.activeChapterTitles,
    required this.createdAt,
    required this.updatedAt,
    this.failure,
  });

  final String jobId;
  final String sourceId;
  final String comicId;
  final String comicTitle;
  final WholeComicQueuePhase phase;
  final int completedChapters;
  final int totalChapters;
  final List<String> activeChapterTitles;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? failure;

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

  double get fraction => totalChapters == 0
      ? 0
      : (completedChapters / totalChapters).clamp(0, 1).toDouble();
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
  })  : _downloads = downloads,
        _store = store ?? MemoryWholeComicQueueStore(),
        _environment = environment ?? const StaticWholeComicQueueEnvironment(),
        _ownsEnvironment = environment == null || ownsEnvironment {
    _ready = _restore();
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
  final WholeComicQueueEnvironmentSource _environment;
  final bool _ownsEnvironment;
  final StreamController<WholeComicQueueSnapshot> _changes =
      StreamController<WholeComicQueueSnapshot>.broadcast(sync: true);
  final Map<String, _WholeComicQueueJob> _jobs =
      <String, _WholeComicQueueJob>{};
  final Map<String, _ActiveQueueChapter> _active =
      <String, _ActiveQueueChapter>{};

  late final Future<void> _ready;
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

  Future<void> enqueue({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    required Iterable<ImportedLibraryEntry> chapters,
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

  Future<void> pause(String jobId) async {
    await ready;
    final job = _requireJob(jobId);
    if (job.phase == WholeComicQueuePhase.complete ||
        job.phase == WholeComicQueuePhase.cancelled) {
      return;
    }
    job.phase = WholeComicQueuePhase.paused;
    job.failure = null;
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
    job.touch();
    await _publish();
    _requestSchedule();
  }

  Future<void> retry(String jobId) async {
    await ready;
    final job = _requireJob(jobId);
    if (job.phase != WholeComicQueuePhase.failed &&
        job.phase != WholeComicQueuePhase.cancelled) {
      return;
    }
    await _refreshCompleted(job);
    job.phase = job.completedChapterIdentities.length == job.chapters.length
        ? WholeComicQueuePhase.complete
        : WholeComicQueuePhase.queued;
    job.failure = null;
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
    await _publish();
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
            continue;
          }
          final job = _WholeComicQueueJob.fromJson(
            rawJob.cast<String, Object?>(),
          );
          if (job.phase == WholeComicQueuePhase.running) {
            job.phase = WholeComicQueuePhase.queued;
          }
          _jobs[job.jobId] = job;
        }
      }
    }
    for (final job in _jobs.values) {
      await _refreshCompleted(job);
      if (job.completedChapterIdentities.length == job.chapters.length) {
        job.phase = WholeComicQueuePhase.complete;
        job.failure = null;
      }
    }
    await _publish();
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
            job.completedChapterIdentities.length == job.chapters.length) {
          job.phase = WholeComicQueuePhase.complete;
          job.failure = null;
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
        if (!job.completedChapterIdentities.contains(identity) &&
            !_active.containsKey(identity)) {
          return (job, entry);
        }
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
    try {
      final current = await _downloads.inspect(entry);
      if (!current.isComplete) {
        await _downloads.download(entry);
      }
      final next = await _downloads.inspect(entry);
      if (next.isComplete) {
        job.completedChapterIdentities.add(identity);
      } else if (!_closing &&
          job.phase != WholeComicQueuePhase.paused &&
          job.phase != WholeComicQueuePhase.waitingForPolicy &&
          job.phase != WholeComicQueuePhase.cancelled) {
        job.phase = WholeComicQueuePhase.failed;
        job.failure = next.failure ?? '章节“${entry.chapter.displayName}”未完成';
      }
    } on Object catch (error) {
      if (!_closing &&
          job.phase != WholeComicQueuePhase.paused &&
          job.phase != WholeComicQueuePhase.waitingForPolicy &&
          job.phase != WholeComicQueuePhase.cancelled) {
        job.phase = WholeComicQueuePhase.failed;
        job.failure = error.toString();
      }
    } finally {
      _active.remove(identity);
      job.touch();
      if (job.phase == WholeComicQueuePhase.failed) {
        await _cancelActiveForJob(job.jobId);
      }
      await _publish();
      _requestSchedule();
    }
  }

  Future<void> _refreshCompleted(_WholeComicQueueJob job) async {
    final completed = <String>{};
    for (final entry in job.chapters) {
      try {
        if ((await _downloads.inspect(entry)).isComplete) {
          completed.add(_chapterIdentity(entry));
        }
      } on Object {
        // Missing/stale artifacts remain queued and are redownloaded.
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
        await _downloads.cancel(item.entry);
        try {
          await item.run;
        } on Object {
          // The chapter task already published its terminal state.
        }
      }),
    );
  }

  Future<void> _cancelAllActive() async {
    final active = _active.values.toList(growable: false);
    await Future.wait<void>(
      active.map((item) async {
        await _downloads.cancel(item.entry);
        try {
          await item.run;
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
      'schema': 1,
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
  });

  final String jobId;
  final String sourceId;
  final String comicId;
  final String comicTitle;
  final List<ImportedLibraryEntry> chapters;
  final Set<String> completedChapterIdentities;
  WholeComicQueuePhase phase;
  String? failure;
  final DateTime createdAt;
  DateTime updatedAt;

  void touch() => updatedAt = DateTime.now().toUtc();

  WholeComicQueueJobSnapshot snapshot({required Iterable<String> active}) =>
      WholeComicQueueJobSnapshot(
        jobId: jobId,
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle,
        phase: phase,
        completedChapters: completedChapterIdentities.length,
        totalChapters: chapters.length,
        activeChapterTitles: List<String>.unmodifiable(active),
        createdAt: createdAt,
        updatedAt: updatedAt,
        failure: failure,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'jobId': jobId,
        'sourceId': sourceId,
        'comicId': comicId,
        'comicTitle': comicTitle,
        'phase': phase.name,
        'failure': failure,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'completedChapterIdentities':
            completedChapterIdentities.toList(growable: false),
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
    return _WholeComicQueueJob(
      jobId: _requiredString(json, 'jobId'),
      sourceId: _requiredString(json, 'sourceId'),
      comicId: _requiredString(json, 'comicId'),
      comicTitle: _requiredString(json, 'comicTitle'),
      chapters: chapters,
      completedChapterIdentities: rawCompleted is List<Object?>
          ? rawCompleted.whereType<String>().toSet()
          : <String>{},
      phase: _enumByName(
        WholeComicQueuePhase.values,
        json['phase'],
        WholeComicQueuePhase.queued,
      ),
      failure: json['failure'] as String?,
      createdAt: DateTime.parse(_requiredString(json, 'createdAt')).toUtc(),
      updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')).toUtc(),
    );
  }
}

String _chapterIdentity(ImportedLibraryEntry entry) => chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

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
