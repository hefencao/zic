import 'package:domain/domain.dart';

typedef VersionPageCanonicalResolver = Iterable<DownloadId> Function(
  DownloadId id,
);

/// Composition-owned canonical logical owner for version-equivalent pages.
///
/// Version/catalog code contributes directional resolvers such as
/// predecessor -> successor. Transfer, partial and artifact owners consume the
/// resolved [DownloadId]; they do not independently walk version history.
/// Resolver replacement is scoped so refreshed relation evidence can revoke
/// stale projections without touching unrelated authorities.
final class VersionPageAuthority {
  final Map<String, Map<String, VersionPageCanonicalResolver>> _scopes =
      <String, Map<String, VersionPageCanonicalResolver>>{};

  int get scopeCount => _scopes.length;
  int get resolverCount => _scopes.values
      .fold<int>(0, (total, resolvers) => total + resolvers.length);

  void replaceScope(
    String scope,
    Map<String, VersionPageCanonicalResolver> resolvers,
  ) {
    if (scope.isEmpty) {
      throw ArgumentError.value(scope, 'scope', 'must not be empty');
    }
    if (resolvers.isEmpty) {
      _scopes.remove(scope);
      return;
    }
    final normalized = <String, VersionPageCanonicalResolver>{};
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

  DownloadId resolve(DownloadId id) {
    final original = id;
    var current = id;
    final visited = <DownloadId>{id};
    for (var depth = 0; depth < 32; depth++) {
      final candidates = <DownloadId>{};
      for (final resolvers in _scopes.values) {
        for (final resolver in resolvers.values) {
          for (final candidate in resolver(current)) {
            if (candidate != current) candidates.add(candidate);
          }
        }
      }
      if (candidates.isEmpty) return current;
      if (candidates.length != 1) {
        // A branched/version-ambiguous page cannot have one canonical owner.
        // Keep its original exact identity rather than selecting by insertion
        // order or version timestamp.
        return original;
      }
      final next = candidates.single;
      if (!visited.add(next)) {
        // Canonical ownership must be directional. A cycle means the supplied
        // projections disagree, so fail closed to the caller's exact identity.
        return original;
      }
      current = next;
    }
    return original;
  }
}
