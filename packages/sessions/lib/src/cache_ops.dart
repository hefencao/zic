import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

import 'download_registry.dart';

final class CacheReport {
  const CacheReport({
    required this.requestedBytes,
    required this.releasedBytes,
    required this.evicted,
    required this.skippedBusy,
    required this.skippedProtected,
    required this.remainingBytes,
  });

  final int requestedBytes;
  final int releasedBytes;
  final int evicted;
  final int skippedBusy;
  final int skippedProtected;
  final int remainingBytes;
}

final class CacheOps {
  CacheOps({
    required this.index,
    required this.registry,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.policy = const CachePolicy(),
    this.evictRecord,
    this.evictRecordWithSnapshot,
  });

  final CacheIndex index;
  final DownloadRegistry registry;
  final MonoClock clock;
  final TraceSink traceSink;
  final CachePolicy policy;

  /// Optional owner-side DeletePlan. When present, physical cleanup and
  /// binding removal are performed by the artifact owner rather than by the
  /// raw session registry, so shared artifacts cannot be deleted by one
  /// logical binding.
  final Future<int> Function(DownloadId id)? evictRecord;

  /// Snapshot-aware owner callback used to close the check-to-delete window
  /// after the policy plan has yielded. The owner must compare [expected]
  /// again inside its serialized mutation boundary before removing bytes.
  final Future<int> Function(DownloadId id, CacheRec expected)?
      evictRecordWithSnapshot;

  Future<CacheReport> trim(
    CacheLimits limits, {
    Set<DownloadId> protected = const <DownloadId>{},
    Set<DownloadId> busy = const <DownloadId>{},
  }) async {
    final records = await index.list();
    final protectedKeys = protected.map((id) => id.key).toSet()
      ..addAll(await _pinnedKeys(records));
    final busyKeys = <String>{
      for (final session in registry.sessions)
        if (!session.canEvict) session.id.key,
      for (final id in busy) id.key,
    };
    final plan = policy.plan(
      records: records,
      limits: limits,
      protectedKeys: <String>{...protectedKeys, ...busyKeys},
    );
    return _apply(
      records: plan.candidates,
      requestedBytes: plan.plannedBytes,
      // Keep busy records out of this set so the report does not count them
      // as both protected and busy. The policy still receives the union above
      // and therefore never schedules them as candidates.
      protectedKeys: protectedKeys,
      busyKeys: busyKeys,
      initialSkippedBusy: records
          .where((record) => busyKeys.contains(record.key))
          .length,
    );
  }

  Future<CacheReport> clear({
    Set<DownloadId> protected = const <DownloadId>{},
    Set<DownloadId> busy = const <DownloadId>{},
  }) async {
    final records = await index.list();
    final protectedKeys = protected.map((id) => id.key).toSet()
      ..addAll(await _pinnedKeys(records));
    final busyKeys = <String>{
      for (final session in registry.sessions)
        if (!session.canEvict) session.id.key,
      for (final id in busy) id.key,
    };
    return _apply(
      records: records,
      requestedBytes: records.fold<int>(0, (sum, rec) => sum + rec.bytes),
      protectedKeys: protectedKeys,
      busyKeys: busyKeys,
    );
  }

  /// Explicitly downloaded chapters survive capacity trims and cache clears;
  /// only a per-chapter delete may remove them.
  Future<Set<String>> _pinnedKeys(Iterable<CacheRec> records) async {
    final placements = await index.listPlacements();
    final owners = <String>{
      for (final placement in placements) placement.ownerKey,
    };
    return <String>{
      for (final record in records)
        if (record.pinned ||
            owners.contains(
              '${record.id.content.sourceId}\u0000${record.id.content.comicId}',
            ))
          record.key,
    };
  }

  Future<CacheReport> _apply({
    required Iterable<CacheRec> records,
    required int requestedBytes,
    required Set<String> protectedKeys,
    Set<String> busyKeys = const <String>{},
    int initialSkippedBusy = 0,
  }) async {
    var released = 0;
    var evicted = 0;
    var skippedBusy = initialSkippedBusy;
    var skippedProtected = 0;
    var skippedStale = 0;

    var step = 0;
    for (final record in records) {
      step++;
      if (step % 20 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      if (busyKeys.contains(record.key)) {
        skippedBusy++;
        continue;
      }
      if (protectedKeys.contains(record.key)) {
        skippedProtected++;
        continue;
      }
      // The policy plan is made from a snapshot. A read touch, rebinding,
      // pin change, or replacement may have happened before this candidate is
      // reached; never pass the stale logical key to an owner-side deleter.
      final current = await index.get(record.key);
      if (current == null || !_sameEvictionRecord(record, current)) {
        skippedStale++;
        continue;
      }
      final session = registry.find(record.id);
      if (session != null && !session.canEvict) {
        skippedBusy++;
        continue;
      }
      try {
        final removed = await (evictRecordWithSnapshot?.call(
              record.id,
              record,
            ) ??
            evictRecord?.call(record.id) ??
            registry.evict(record.id));
        released += removed;
        if (removed > 0) evicted++;
      } on Failure catch (error) {
        if (error.code == ErrorCode.writerBusy ||
            error.code == ErrorCode.sessionBusy) {
          skippedBusy++;
          continue;
        }
        rethrow;
      }
    }

    final remaining = await index.totalBytes();
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: 'cache',
        kind: TraceEventKind.cacheTrim,
        payload: <String, Object?>{
          'requestedBytes': requestedBytes,
          'releasedBytes': released,
          'evicted': evicted,
          'skippedBusy': skippedBusy,
          'skippedProtected': skippedProtected,
          'skippedStale': skippedStale,
          'remainingBytes': remaining,
        },
      ),
    );
    return CacheReport(
      requestedBytes: requestedBytes,
      releasedBytes: released,
      evicted: evicted,
      skippedBusy: skippedBusy,
      skippedProtected: skippedProtected,
      remainingBytes: remaining,
    );
  }

  bool _sameEvictionRecord(CacheRec first, CacheRec second) =>
      first.id == second.id &&
      first.state == second.state &&
      first.path == second.path &&
      first.bytes == second.bytes &&
      first.checksum.trim().toLowerCase() ==
          second.checksum.trim().toLowerCase() &&
      first.createdUs == second.createdUs &&
      first.touchedUs == second.touchedUs &&
      first.pinned == second.pinned &&
      first.checksumAlgorithm.trim().toLowerCase() ==
          second.checksumAlgorithm.trim().toLowerCase() &&
      first.effectiveArtifactId == second.effectiveArtifactId &&
      first.storageRootId == second.storageRootId;
}
