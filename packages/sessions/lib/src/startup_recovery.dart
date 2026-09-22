import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

final class RecoveryReport {
  const RecoveryReport({required this.scan, required this.sessions});

  final ScanReport scan;

  /// Kept for trace/API compatibility. Durable startup recovery no longer
  /// recreates DownloadSessions from cache rows; sealed and partial bytes are
  /// opened lazily by their durable owners when a consumer actually asks.
  final int sessions;
}

final class StartupRecovery {
  const StartupRecovery({
    required this.layout,
    required this.index,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
  });

  final CacheLayout layout;
  final CacheIndex index;
  final MonoClock clock;
  final TraceSink traceSink;

  Future<RecoveryReport> run() async {
    await index.open();
    final scanStartedUs = clock.nowMicros();
    final scan = await CacheScanner(
      layout: layout,
      index: index,
    ).scan();
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: 'startup',
        kind: TraceEventKind.cacheScan,
        payload: <String, Object?>{
          'scanMicros': clock.nowMicros() - scanStartedUs,
          'phaseMicros': scan.phaseMicros,
          'recovered': scan.recovered,
          'removedRecords': scan.removedRecords,
          'deletedOrphans': scan.deletedOrphans,
          'protected': scan.protected,
          'invalidMeta': scan.invalidMeta,
          'sessions': 0,
        },
      ),
    );
    return RecoveryReport(scan: scan, sessions: 0);
  }
}
