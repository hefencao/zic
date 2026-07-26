import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

import 'download_registry.dart';

final class RecoveryReport {
  const RecoveryReport({required this.scan, required this.sessions});

  final ScanReport scan;
  final int sessions;
}

final class StartupRecovery {
  const StartupRecovery({
    required this.layout,
    required this.index,
    required this.registry,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
  });

  final CacheLayout layout;
  final CacheIndex index;
  final DownloadRegistry registry;
  final MonoClock clock;
  final TraceSink traceSink;

  Future<RecoveryReport> run() async {
    await index.open();
    final scan = await CacheScanner(
      layout: layout,
      index: index,
      activePaths: registry.activePaths,
    ).scan();
    final sessions = await registry.restoreIndexed();
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: 'startup',
        kind: TraceEventKind.cacheScan,
        payload: <String, Object?>{
          'recovered': scan.recovered,
          'removedRecords': scan.removedRecords,
          'deletedOrphans': scan.deletedOrphans,
          'protected': scan.protected,
          'invalidMeta': scan.invalidMeta,
          'sessions': sessions,
        },
      ),
    );
    return RecoveryReport(scan: scan, sessions: sessions);
  }
}
