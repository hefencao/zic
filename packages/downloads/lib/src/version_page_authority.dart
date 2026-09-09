import 'package:domain/domain.dart';

typedef VersionPageReuseResolver = Iterable<DownloadId> Function(
  DownloadId id,
);

/// Composition-owned verified page-reuse authority across comic versions.
///
/// Catalog/library code contributes scoped direct-equivalence projections.
/// This authority never changes a logical page into a newer logical owner by
/// itself. Cache, partial and hot-transfer owners consume the same candidate
/// set and may reuse an already-existing physical state; exact writes remain
/// owned by the logical [DownloadId] requested by the caller.
final class VersionPageAuthority {
  final Map<String, Map<String, VersionPageReuseResolver>> _scopes =
      <String, Map<String, VersionPageReuseResolver>>{};

  int get scopeCount => _scopes.length;
  int get resolverCount => _scopes.values
      .fold<int>(0, (total, resolvers) => total + resolvers.length);

  void replaceScope(
    String scope,
    Map<String, VersionPageReuseResolver> resolvers,
  ) {
    if (scope.isEmpty) {
      throw ArgumentError.value(scope, 'scope', 'must not be empty');
    }
    if (resolvers.isEmpty) {
      _scopes.remove(scope);
      return;
    }
    final normalized = <String, VersionPageReuseResolver>{};
    for (final entry in resolvers.entries) {
      if (entry.key.isEmpty) {
        throw ArgumentError.value(entry.key, 'resolver key', 'must not be empty');
      }
      normalized[entry.key] = entry.value;
    }
    _scopes
      ..remove(scope)
      ..[scope] = normalized;
  }

  void removeScope(String scope) {
    _scopes.remove(scope);
  }

  void clear() {
    _scopes.clear();
  }

  /// Returns direct verified version-page candidates for [id].
  ///
  /// No transitive walk is performed here: a candidate only matters if a
  /// downstream physical authority actually exists. This keeps version graph
  /// facts separate from logical ownership and prevents a newer source version
  /// from silently replacing an explicitly requested older version.
  Iterable<DownloadId> directCandidates(DownloadId id) sync* {
    final candidates = <DownloadId>{};
    for (final resolvers in _scopes.values) {
      for (final resolver in resolvers.values) {
        for (final candidate in resolver(id)) {
          if (candidate != id) candidates.add(candidate);
        }
      }
    }
    yield* candidates;
  }
}
