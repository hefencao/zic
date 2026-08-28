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
  });

  final CacheIndex index;
  final DownloadRegistry registry;
  final MonoClock clock;
  final TraceSink traceSink;
  final CachePolicy policy;

  Future<CacheReport> trim(
    CacheLimits limits, {
    Set<DownloadId> protected = const <DownloadId>{},
  }) async {
    final records = await index.list();
    final protectedKeys = protected.map((id) => id.key).toSet()
      ..addAll(_pinnedKeys(records));
    final busyKeys = <String>{
      for (final session in registry.sessions)
        if (!session.canEvict) session.id.key,
    };
    final plan = policy.plan(
      records: records,
      limits: limits,
      protectedKeys: <String>{...protectedKeys, ...busyKeys},
    );
    return _apply(
      records: plan.candidates,
      requestedBytes: plan.plannedBytes,
      protectedKeys: protectedKeys,
      initialSkippedBusy: records
          .where((record) => busyKeys.contains(record.key))
          .length,
    );
  }

  Future<CacheReport> clear({
    Set<DownloadId> protected = const <DownloadId>{},
  }) async {
    final records = await index.list();
    final protectedKeys = protected.map((id) => id.key).toSet()
      ..addAll(_pinnedKeys(records));
    return _apply(
      records: records,
      requestedBytes: records.fold<int>(0, (sum, rec) => sum + rec.bytes),
      protectedKeys: protectedKeys,
    );
  }

  /// Explicitly downloaded chapters survive capacity trims and cache clears;
  /// only a per-chapter delete may remove them.
  Set<String> _pinnedKeys(Iterable<CacheRec> records) =>
      <String>{for (final record in records) if (record.pinned) record.key};

  Future<CacheReport> _apply({
    required Iterable<CacheRec> records,
    required int requestedBytes,
    required Set<String> protectedKeys,
    int initialSkippedBusy = 0,
  }) async {
    var released = 0;
    var evicted = 0;
    var skippedBusy = initialSkippedBusy;
    var skippedProtected = 0;

    for (final record in records) {
      if (protectedKeys.contains(record.key)) {
        skippedProtected++;
        continue;
      }
      final session = registry.find(record.id);
      if (session != null && !session.canEvict) {
        skippedBusy++;
        continue;
      }
      try {
        released += await registry.evict(record.id);
        evicted++;
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
}
