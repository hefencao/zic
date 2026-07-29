import 'dart:async';

/// Logical resource families sharing one cache manager and global budget.
///
/// Encoded Reader pages are intentionally absent: their lifecycle is owned by
/// pipeline demand, sessions and the artifact tier rather than catalog response
/// caching.
enum ResourceCacheKind {
  imageBytes,
  comicDetails,
  chapterMetadata,
  searchResults,
}

/// Stable cache identity plus an invalidation namespace.
///
/// [identity] identifies one response. [namespace] groups related responses,
/// such as all cover/detail/chapter metadata for one source-composite comic.
final class ResourceCacheKey {
  const ResourceCacheKey({
    required this.kind,
    required this.identity,
    this.namespace = '',
    this.revision = '',
  }) : assert(identity != '');

  final ResourceCacheKind kind;
  final String identity;
  final String namespace;
  final String revision;

  @override
  bool operator ==(Object other) =>
      other is ResourceCacheKey &&
      other.kind == kind &&
      other.identity == identity &&
      other.namespace == namespace &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(kind, identity, namespace, revision);

  @override
  String toString() =>
      '${kind.name}:$identity@$revision${namespace.isEmpty ? '' : ' [$namespace]'}';
}

final class ResourceCachePolicy {
  const ResourceCachePolicy({
    required this.maxEntries,
    required this.maxWeight,
    required this.ttl,
  })  : assert(maxEntries > 0),
        assert(maxWeight > 0);

  final int maxEntries;
  final int maxWeight;
  final Duration ttl;
}

final class ResourceCacheKindStats {
  const ResourceCacheKindStats({
    required this.entries,
    required this.inFlight,
    required this.weight,
  });

  final int entries;
  final int inFlight;
  final int weight;
}

final class ResourceCacheStats {
  ResourceCacheStats({
    required this.entries,
    required this.inFlight,
    required this.weight,
    required this.hits,
    required this.misses,
    required this.evictions,
    required this.expirations,
    required Map<ResourceCacheKind, ResourceCacheKindStats> byKind,
  }) : byKind = Map<ResourceCacheKind, ResourceCacheKindStats>.unmodifiable(
          byKind,
        );

  final int entries;
  final int inFlight;
  final int weight;
  final int hits;
  final int misses;
  final int evictions;
  final int expirations;
  final Map<ResourceCacheKind, ResourceCacheKindStats> byKind;

  ResourceCacheKindStats forKind(ResourceCacheKind kind) =>
      byKind[kind] ??
      const ResourceCacheKindStats(entries: 0, inFlight: 0, weight: 0);
}

typedef ResourceCacheWeight<T extends Object> = int Function(T value);

/// One cache owner for catalog and reusable resource responses.
///
/// The manager coalesces concurrent loads, applies per-kind and global LRU
/// budgets, expires metadata by TTL and exposes exact namespace invalidation.
/// It does not own Reader page artifacts, decoded frames or textures.
final class ResourceCacheManager {
  ResourceCacheManager({
    Map<ResourceCacheKind, ResourceCachePolicy>? policies,
    this.globalMaxWeight = 64 * 1024 * 1024,
    DateTime Function()? now,
  })  : assert(globalMaxWeight > 0),
        _policies = Map<ResourceCacheKind, ResourceCachePolicy>.unmodifiable(
          policies ?? standardPolicies,
        ),
        _now = now ?? DateTime.now {
    for (final kind in ResourceCacheKind.values) {
      if (!_policies.containsKey(kind)) {
        throw ArgumentError('missing cache policy for ${kind.name}');
      }
    }
  }

  static const Map<ResourceCacheKind, ResourceCachePolicy> standardPolicies =
      <ResourceCacheKind, ResourceCachePolicy>{
    ResourceCacheKind.imageBytes: ResourceCachePolicy(
      maxEntries: 96,
      maxWeight: 32 * 1024 * 1024,
      ttl: Duration(minutes: 30),
    ),
    ResourceCacheKind.comicDetails: ResourceCachePolicy(
      maxEntries: 64,
      maxWeight: 2 * 1024 * 1024,
      ttl: Duration(minutes: 10),
    ),
    ResourceCacheKind.chapterMetadata: ResourceCachePolicy(
      maxEntries: 512,
      maxWeight: 8 * 1024 * 1024,
      ttl: Duration(minutes: 10),
    ),
    ResourceCacheKind.searchResults: ResourceCachePolicy(
      maxEntries: 96,
      maxWeight: 8 * 1024 * 1024,
      ttl: Duration(minutes: 2),
    ),
  };

  final Map<ResourceCacheKind, ResourceCachePolicy> _policies;
  final int globalMaxWeight;
  final DateTime Function() _now;
  final Map<ResourceCacheKey, _ResourceCacheEntry> _entries =
      <ResourceCacheKey, _ResourceCacheEntry>{};
  final Map<ResourceCacheKey, Future<Object>> _inFlight =
      <ResourceCacheKey, Future<Object>>{};
  final Map<ResourceCacheKey, int> _generations = <ResourceCacheKey, int>{};
  final Map<ResourceCacheKey, int> _activeLoads = <ResourceCacheKey, int>{};

  var _clock = 0;
  var _epoch = 0;
  var _weight = 0;
  var _hits = 0;
  var _misses = 0;
  var _evictions = 0;
  var _expirations = 0;
  bool _closed = false;

  ResourceCacheStats get stats {
    final byKind = <ResourceCacheKind, ResourceCacheKindStats>{};
    for (final kind in ResourceCacheKind.values) {
      byKind[kind] = ResourceCacheKindStats(
        entries: _kindEntries(kind),
        inFlight: _kindInFlight(kind),
        weight: _kindWeight(kind),
      );
    }
    return ResourceCacheStats(
      entries: _entries.length,
      inFlight: _activeLoads.values.fold<int>(
        0,
        (sum, count) => sum + count,
      ),
      weight: _weight,
      hits: _hits,
      misses: _misses,
      evictions: _evictions,
      expirations: _expirations,
      byKind: byKind,
    );
  }

  Future<T> getOrLoad<T extends Object>({
    required ResourceCacheKey key,
    required Future<T> Function() loader,
    required ResourceCacheWeight<T> weightOf,
    bool forceRefresh = false,
  }) {
    _requireOpen();
    if (!forceRefresh) {
      final cached = _read<T>(key);
      if (cached != null) {
        _hits++;
        return Future<T>.value(cached);
      }
      final pending = _inFlight[key];
      if (pending != null) {
        _hits++;
        return pending.then((value) => value as T);
      }
    } else {
      invalidate(key);
    }

    _misses++;
    final generation = _generationOf(key);
    final epoch = _epoch;
    _activeLoads[key] = (_activeLoads[key] ?? 0) + 1;
    final future = Future<T>.sync(loader).then((value) {
      if (_closed || epoch != _epoch || generation != _generationOf(key)) {
        return value;
      }
      final weight = weightOf(value);
      if (weight < 0) {
        throw StateError('cache weight must not be negative for $key');
      }
      final policy = _policies[key.kind]!;
      if (weight <= policy.maxWeight && weight <= globalMaxWeight) {
        _store(key, value, weight, policy.ttl);
      }
      return value;
    });
    final Future<Object> shared = future;
    _inFlight[key] = shared;
    return future.whenComplete(() {
      if (identical(_inFlight[key], shared)) {
        _inFlight.remove(key);
      }
      _finishLoad(key);
    });
  }

  T? peek<T extends Object>(ResourceCacheKey key) {
    _requireOpen();
    return _read<T>(key);
  }

  void invalidate(ResourceCacheKey key) {
    _generations[key] = _generationOf(key) + 1;
    _inFlight.remove(key);
    _removeEntry(key);
  }

  void invalidateKind(ResourceCacheKind kind) {
    invalidateWhere((key) => key.kind == kind);
  }

  void invalidateNamespace(String namespace) {
    if (namespace.isEmpty) {
      return;
    }
    invalidateWhere((key) => key.namespace == namespace);
  }

  void invalidateWhere(bool Function(ResourceCacheKey key) predicate) {
    final keys = <ResourceCacheKey>{
      ..._entries.keys,
      ..._inFlight.keys,
    }.where(predicate).toList(growable: false);
    for (final key in keys) {
      invalidate(key);
    }
  }

  int trimTo({required int targetWeight}) {
    _requireOpen();
    if (targetWeight < 0) {
      throw ArgumentError.value(targetWeight, 'targetWeight');
    }
    final before = _weight;
    _expireEntries();
    while (_weight > targetWeight && _entries.isNotEmpty) {
      final victim = _entries.entries.reduce(
        (left, right) =>
            left.value.touched <= right.value.touched ? left : right,
      );
      _removeEntry(victim.key);
      _evictions++;
    }
    return before - _weight;
  }

  void clear() {
    _epoch++;
    _entries.clear();
    _inFlight.clear();
    _generations.clear();
    _weight = 0;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final pending = _inFlight.values.toList(growable: false);
    _epoch++;
    _entries.clear();
    _inFlight.clear();
    _generations.clear();
    _activeLoads.clear();
    _weight = 0;
    if (pending.isNotEmpty) {
      await Future.wait<void>(
        pending.map((future) async {
          try {
            await future;
          } on Object {
            // A failed resource request remains owned by its caller.
          }
        }),
      );
    }
  }

  T? _read<T extends Object>(ResourceCacheKey key) {
    final entry = _entries[key];
    if (entry == null) {
      return null;
    }
    if (!entry.expiresAt.isAfter(_now())) {
      _removeEntry(key);
      _expirations++;
      return null;
    }
    final value = entry.value;
    if (value is! T) {
      invalidate(key);
      return null;
    }
    entry.touched = ++_clock;
    return value;
  }

  void _store(
    ResourceCacheKey key,
    Object value,
    int weight,
    Duration ttl,
  ) {
    _removeEntry(key);
    _entries[key] = _ResourceCacheEntry(
      value: value,
      weight: weight,
      touched: ++_clock,
      expiresAt: _now().add(ttl),
    );
    _weight += weight;
    _enforceBudgets(key.kind, protectedKey: key);
  }

  void _enforceBudgets(
    ResourceCacheKind kind, {
    required ResourceCacheKey protectedKey,
  }) {
    final policy = _policies[kind]!;
    while (_kindEntries(kind) > policy.maxEntries ||
        _kindWeight(kind) > policy.maxWeight ||
        _weight > globalMaxWeight) {
      MapEntry<ResourceCacheKey, _ResourceCacheEntry>? victim;
      for (final candidate in _entries.entries) {
        if (candidate.key == protectedKey) {
          continue;
        }
        if (_weight <= globalMaxWeight && candidate.key.kind != kind) {
          continue;
        }
        if (victim == null || candidate.value.touched < victim.value.touched) {
          victim = candidate;
        }
      }
      if (victim == null) {
        return;
      }
      _removeEntry(victim.key);
      _evictions++;
    }
  }

  void _expireEntries() {
    final now = _now();
    for (final entry in _entries.entries.toList(growable: false)) {
      if (!entry.value.expiresAt.isAfter(now)) {
        _removeEntry(entry.key);
        _expirations++;
      }
    }
  }

  void _removeEntry(ResourceCacheKey key) {
    final removed = _entries.remove(key);
    if (removed != null) {
      _weight -= removed.weight;
    }
  }

  void _finishLoad(ResourceCacheKey key) {
    final remaining = (_activeLoads[key] ?? 1) - 1;
    if (remaining > 0) {
      _activeLoads[key] = remaining;
      return;
    }
    _activeLoads.remove(key);
    if (!_inFlight.containsKey(key)) {
      _generations.remove(key);
    }
  }

  int _generationOf(ResourceCacheKey key) => _generations[key] ?? 0;

  int _kindInFlight(ResourceCacheKind kind) => _activeLoads.entries
      .where((entry) => entry.key.kind == kind)
      .fold<int>(0, (sum, entry) => sum + entry.value);

  int _kindEntries(ResourceCacheKind kind) =>
      _entries.keys.where((key) => key.kind == kind).length;

  int _kindWeight(ResourceCacheKind kind) => _entries.entries
      .where((entry) => entry.key.kind == kind)
      .fold<int>(0, (sum, entry) => sum + entry.value.weight);

  void _requireOpen() {
    if (_closed) {
      throw StateError('resource cache is closed');
    }
  }
}

final class _ResourceCacheEntry {
  _ResourceCacheEntry({
    required this.value,
    required this.weight,
    required this.touched,
    required this.expiresAt,
  });

  final Object value;
  final int weight;
  int touched;
  final DateTime expiresAt;
}
