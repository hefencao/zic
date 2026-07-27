import 'package:domain/domain.dart';

import 'ingress.dart';
import 'source.dart';

typedef SourceBudget = int Function(DownloadId id);

final class SourcePool {
  SourcePool({
    required this.factory,
    required this.budgetFor,
  });

  final SourceFactory factory;
  final SourceBudget budgetFor;
  final Map<DownloadId, Ingress> _entries = <DownloadId, Ingress>{};

  Iterable<DownloadId> get ids => _entries.keys;

  Ingress get(DownloadId id) => _entries.putIfAbsent(
        id,
        () => Ingress(factory: factory, maxBytes: budgetFor(id)),
      );

  Ingress? find(DownloadId id) => _entries[id];

  bool remove(DownloadId id) {
    final ingress = _entries.remove(id);
    ingress?.dispose();
    return ingress != null;
  }

  void dispose() {
    for (final ingress in _entries.values) {
      ingress.dispose();
    }
    _entries.clear();
  }
}
