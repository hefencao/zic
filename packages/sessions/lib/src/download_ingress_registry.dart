import 'package:domain/domain.dart';
import 'package:media/media.dart';

import 'download_ingress_projection.dart';
import 'download_session.dart';

/// Reader-local registry for native ingress projections.
///
/// This registry deliberately does not own physical [DownloadSession] objects.
/// It can therefore survive a later lift of the physical transfer registry to
/// composition scope while decode/upload remain Reader-local.
final class DownloadIngressProjectionRegistry {
  DownloadIngressProjectionRegistry({
    required this.sources,
    required this.scopePrefix,
  });

  final SourcePool sources;
  final String scopePrefix;
  final Map<DownloadId, DownloadIngressProjection> _entries =
      <DownloadId, DownloadIngressProjection>{};

  Iterable<DownloadIngressProjection> get projections => _entries.values;

  DownloadIngressProjection attach(DownloadSession session) {
    final existing = _entries[session.id];
    if (existing != null) return existing;
    final projection = DownloadIngressProjection(
      scopeId: '$scopePrefix:${session.id.key}',
      ingress: sources.get(session.id),
    );
    session.attachIngressProjection(projection);
    _entries[session.id] = projection;
    return projection;
  }

  DownloadIngressProjection get(DownloadSession session) =>
      _entries[session.id] ?? attach(session);

  DownloadIngressProjection? find(DownloadId id) => _entries[id];

  void detach(DownloadSession session) {
    final projection = _entries.remove(session.id);
    if (projection == null) return;
    session.detachIngressProjection(projection.scopeId);
    projection.detach();
  }

  void dispose(Iterable<DownloadSession> sessions) {
    for (final session in sessions) {
      detach(session);
    }
    _entries.clear();
  }
}
