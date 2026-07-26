import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'coordinator.dart';
import 'download_job.dart';
import 'download_registry.dart';
import 'net_lane.dart';

typedef TransportPick = Transport Function(Uri uri);

final class LiveCoordinator implements Coordinator {
  LiveCoordinator({
    required this.registry,
    required this.transportFor,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    NetLane? net,
  }) : net = net ?? NetLane(maxActive: 3);

  final DownloadRegistry registry;
  final TransportPick transportFor;
  final MonoClock clock;
  final TraceSink traceSink;
  final NetLane net;

  final Map<DownloadId, DownloadDemand> _demands =
      <DownloadId, DownloadDemand>{};
  int _revision = 0;

  Map<DownloadId, DownloadDemand> get demands =>
      Map<DownloadId, DownloadDemand>.unmodifiable(_demands);

  @override
  void reconcile(String sessionId, PipelineDelta update) {
    _revision = update.plan.revision;
    for (final id in update.diff.downloads.removed) {
      _demands.remove(id);
      net.cancelQueued(id.key);
      registry.find(id)?.detach();
    }
    for (final entry in <MapEntry<DownloadId, DownloadDemand>>[
      ...update.diff.downloads.added.entries,
      ...update.diff.downloads.changed.entries,
    ]) {
      _demands[entry.key] = entry.value;
      final session = registry.get(entry.key)..attach();
      net.submit(
        key: entry.key.key,
        priority: entry.value.priority,
        task: (token) async {
          token.throwIfCancelled();
          final current = _demands[entry.key];
          if (current == null ||
              current.expirationRevision < _revision ||
              !session.demanded) {
            return;
          }
          try {
            await DownloadJob(
              transport: transportFor(entry.key.canonicalUri),
              session: session,
            ).run(cancel: token);
          } on Failure catch (error) {
            if (error.code != ErrorCode.cancelled) {
              _error(sessionId, entry.key, error);
            }
          } on Object catch (error) {
            _error(sessionId, entry.key, error);
          }
        },
      );
    }
  }

  Future<void> idle() => net.idle();

  void _error(String sessionId, DownloadId id, Object error) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.taskFailed,
        identityHash: id.key,
        revision: _revision,
        payload: <String, Object?>{'lane': 'network', 'error': '$error'},
      ),
    );
  }
}
