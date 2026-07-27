import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

abstract interface class Coordinator {
  void reconcile(String sessionId, PipelineDelta update);
}

abstract interface class PlaybackCoordinator {
  void syncPlayback(ViewportState viewport, Map<int, DecodeId> ids);
}

final class FakeCoordinator implements Coordinator, PlaybackCoordinator {
  FakeCoordinator({
    required this.clock,
    this.traceSink = const NoopTraceSink(),
  });

  final MonoClock clock;
  final TraceSink traceSink;

  final Map<DownloadId, DownloadDemand> _downloads =
      <DownloadId, DownloadDemand>{};
  final Map<DecodeId, DecodeDemand> _decodes =
      <DecodeId, DecodeDemand>{};
  final Map<DecodeId, UploadDemand> _uploads =
      <DecodeId, UploadDemand>{};
  final Set<ResourceId> _keep = <ResourceId>{};

  ViewportState? _viewport;
  Map<int, DecodeId> _playbackIds = const <int, DecodeId>{};
  int _playbackSyncs = 0;

  ViewportState? get viewport => _viewport;
  Map<int, DecodeId> get playbackIds =>
      Map<int, DecodeId>.unmodifiable(_playbackIds);
  int get playbackSyncs => _playbackSyncs;

  Map<DownloadId, DownloadDemand> get downloads =>
      Map<DownloadId, DownloadDemand>.unmodifiable(_downloads);
  Map<DecodeId, DecodeDemand> get decodes =>
      Map<DecodeId, DecodeDemand>.unmodifiable(_decodes);
  Map<DecodeId, UploadDemand> get uploads =>
      Map<DecodeId, UploadDemand>.unmodifiable(_uploads);
  Set<ResourceId> get keep => Set<ResourceId>.unmodifiable(_keep);

  @override
  void syncPlayback(ViewportState viewport, Map<int, DecodeId> ids) {
    _viewport = viewport;
    _playbackIds = Map<int, DecodeId>.unmodifiable(ids);
    _playbackSyncs++;
  }

  @override
  void reconcile(String sessionId, PipelineDelta update) {
    _applyMapDiff(
      sessionId: sessionId,
      revision: update.plan.revision,
      diff: update.diff.downloads,
      registry: _downloads,
      identity: (value) => value.key,
      lane: 'download',
    );
    _applyMapDiff(
      sessionId: sessionId,
      revision: update.plan.revision,
      diff: update.diff.decodes,
      registry: _decodes,
      identity: (value) => value.key,
      lane: 'decode',
    );
    _applyMapDiff(
      sessionId: sessionId,
      revision: update.plan.revision,
      diff: update.diff.uploads,
      registry: _uploads,
      identity: (value) => value.key,
      lane: 'upload',
    );
    _keep
      ..removeAll(update.diff.keepRemoved)
      ..addAll(update.diff.keepAdded);
  }

  void _applyMapDiff<K, V>({
    required String sessionId,
    required int revision,
    required MapDiff<K, V> diff,
    required Map<K, V> registry,
    required String Function(K value) identity,
    required String lane,
  }) {
    for (final key in diff.removed) {
      registry.remove(key);
      traceSink.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.demandDetached,
          identityHash: identity(key),
          revision: revision,
          payload: <String, Object?>{'lane': lane},
        ),
      );
    }
    for (final entry in <MapEntry<K, V>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      registry[entry.key] = entry.value;
      traceSink.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.demandApplied,
          identityHash: identity(entry.key),
          revision: revision,
          payload: <String, Object?>{'lane': lane},
        ),
      );
    }
  }
}
