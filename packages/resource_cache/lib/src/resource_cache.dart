import 'dart:async';
import 'dart:typed_data';

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

/// Schema revision shared by all durable comic artwork cache entries.
///
/// Artwork callers may add a content-specific revision, but must never append
/// this schema revision themselves. That prevents browse/details/history from
/// accidentally creating parallel durable namespaces for the same artwork.
const comicArtworkCacheSchemaRevision = 'artwork-v2';

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

/// Durable byte response restored before a source loader is invoked.
///
/// Only immutable encoded response bytes belong here. Reader page artifacts,
/// decoded frames and textures keep their existing owners.
final class PersistedResourceBytes {
  const PersistedResourceBytes({required this.bytes, required this.expiresAt});

  final Uint8List bytes;

  /// Expiry owned by the durable byte store.
  ///
  /// `null` means the record is retained until explicit invalidation/clear.
  /// This is intentionally independent from the bounded in-memory response
  /// cache TTL: a retained cover may leave memory while its durable encoded
  /// bytes remain reusable across process restarts.
  final DateTime? expiresAt;
}

/// Immutable encoded resource presented either from Dart-owned memory or from
/// an externally stable file.
///
/// Raw cache-owned paths are deliberately not exposed through
/// [FileEncodedResourceSource]: the response cache may trim or invalidate those
/// files while a Flutter ImageProvider is still alive. Resource-cache image
/// reads therefore materialize owned bytes before crossing the cache boundary.
/// A durable artifact may use this source only through an explicit file/
/// descriptor lease whose lifetime outlives the provider; [cacheIdentity]
/// then separates process-local descriptor-path reuse from ImageCache identity.
enum EncodedResourceOrigin { memory, localFile, durableCacheFile }

sealed class EncodedResourceSource {
  const EncodedResourceSource({required this.origin, this.lengthInBytes});

  final EncodedResourceOrigin origin;
  final int? lengthInBytes;
}

final class MemoryEncodedResourceSource extends EncodedResourceSource {
  MemoryEncodedResourceSource(
    this.bytes, {
    this.cacheIdentity,
    EncodedResourceOrigin origin = EncodedResourceOrigin.memory,
  }) : super(origin: origin, lengthInBytes: bytes.lengthInBytes);

  final Uint8List bytes;

  /// Optional presentation identity independent from the current backing.
  ///
  /// A Pipeline static image may first be available from generation-local
  /// resident bytes and later from a durable file lease without changing the
  /// immutable encoded generation. Supplying the same opaque identity on both
  /// sources lets the presentation bridge keep one ImageCache key across that
  /// backing handoff. The identity grants no byte/storage authority.
  final Object? cacheIdentity;
}

/// Public Flutter-image cache key envelope for one presentation raster.
///
/// The opaque [presentationIdentity] is owned by Pipeline presentation
/// generation state. [providerKey] is the exact engine-facing key produced by
/// the backing ImageProvider (including resize geometry when present). Keeping
/// both values lets the App-owned ImageCache observe raster residency/eviction
/// without taking ownership of the encoded bytes or decoded raster itself.
final class PresentationRasterCacheKey {
  const PresentationRasterCacheKey({
    required this.presentationIdentity,
    required this.providerKey,
  });

  final Object presentationIdentity;
  final Object providerKey;

  @override
  bool operator ==(Object other) =>
      other is PresentationRasterCacheKey &&
      other.presentationIdentity == presentationIdentity &&
      other.providerKey == providerKey;

  @override
  int get hashCode => Object.hash(presentationIdentity, providerKey);
}

final class FileEncodedResourceSource extends EncodedResourceSource {
  const FileEncodedResourceSource({
    required this.path,
    super.lengthInBytes,
    this.cacheIdentity,
    EncodedResourceOrigin origin = EncodedResourceOrigin.localFile,
  })  : assert(path != ''),
        assert(origin != EncodedResourceOrigin.memory),
        super(origin: origin);

  final String path;

  /// Optional identity independent from [path]. Descriptor paths may reuse an
  /// fd number after release, so leased durable files must provide a unique
  /// generation/lease identity to prevent stale Flutter ImageCache hits.
  final Object? cacheIdentity;
}

/// Persistence lifetime for immutable encoded response bytes.
///
/// This is not part of [ResourceCacheKey] identity. The same canonical artwork
/// can first be observed as a transient source-browse response and later be
/// promoted when it becomes library/history-owned. Promotion is monotonic for
/// the current durable record and must never create a second cache namespace.
enum ResourceCacheRetention {
  transient,
  retained,
}

/// Physical usage reported by an inspectable durable response-byte store.
final class ResourceCacheByteStoreUsage {
  const ResourceCacheByteStoreUsage({
    required this.bytes,
    required this.entries,
    this.retainedBytes = 0,
    this.retainedEntries = 0,
  })  : assert(bytes >= 0),
        assert(entries >= 0),
        assert(retainedBytes >= 0),
        assert(retainedEntries >= 0),
        assert(retainedBytes <= bytes),
        assert(retainedEntries <= entries);

  final int bytes;
  final int entries;
  final int retainedBytes;
  final int retainedEntries;

  int get transientBytes => bytes - retainedBytes;
  int get transientEntries => entries - retainedEntries;
}

final class ResourceCacheByteStoreTrimReport {
  const ResourceCacheByteStoreTrimReport({
    required this.beforeBytes,
    required this.releasedBytes,
    required this.remainingBytes,
    required this.evictedEntries,
  });

  final int beforeBytes;
  final int releasedBytes;
  final int remainingBytes;
  final int evictedEntries;
}

/// Optional maintenance projection for durable response-byte stores.
///
/// Capacity trim applies only to transient records. Retained records are
/// removed only by exact invalidation/namespace invalidation or explicit clear.
abstract interface class ResourceCacheByteStoreMaintenance {
  Future<ResourceCacheByteStoreUsage> inspect();

  Future<ResourceCacheByteStoreTrimReport> trimTo({required int targetBytes});
}

/// Optional durable backing for byte-valued resource-cache entries.
///
/// Implementations must preserve the full [ResourceCacheKey], including its
/// namespace and revision, so invalidation has the same semantics before and
/// after an application restart.
abstract interface class ResourceCacheByteStore {
  Future<PersistedResourceBytes?> read(ResourceCacheKey key);

  Future<void> write({
    required ResourceCacheKey key,
    required Uint8List bytes,
    required DateTime? expiresAt,
    ResourceCacheRetention retention = ResourceCacheRetention.transient,
  });

  /// Promotes an existing durable record to retained lifetime without changing
  /// its cache identity or rewriting the encoded payload.
  ///
  /// Missing records are a no-op: a later write for a retained request carries
  /// the retention intent explicitly.
  Future<void> retain(ResourceCacheKey key);

  Future<void> remove(ResourceCacheKey key);

  Future<void> removeWhere(bool Function(ResourceCacheKey key) predicate);

  Future<void> clear();

  Future<void> close();
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
    required this.persistentHits,
    required this.persistentMisses,
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
  final int persistentHits;
  final int persistentMisses;
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
    this.byteStore,
    this.onPersistenceError,
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
      ttl: Duration(days: 7),
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
  final ResourceCacheByteStore? byteStore;
  final void Function(Object error, StackTrace stackTrace)? onPersistenceError;
  final DateTime Function() _now;
  final Map<ResourceCacheKey, _ResourceCacheEntry> _entries =
      <ResourceCacheKey, _ResourceCacheEntry>{};
  final Map<ResourceCacheKey, Future<Object>> _inFlight =
      <ResourceCacheKey, Future<Object>>{};
  final Map<ResourceCacheKey, int> _generations = <ResourceCacheKey, int>{};
  final Map<ResourceCacheKey, int> _activeLoads = <ResourceCacheKey, int>{};
  final Set<ResourceCacheKey> _retainedPersistence = <ResourceCacheKey>{};

  var _clock = 0;
  var _epoch = 0;
  var _weight = 0;
  var _hits = 0;
  var _misses = 0;
  var _evictions = 0;
  var _expirations = 0;
  var _persistentHits = 0;
  var _persistentMisses = 0;
  Future<void> _persistenceTail = Future<void>.value();
  Future<void>? _closeFuture;
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
      inFlight: _activeLoads.values.fold<int>(0, (sum, count) => sum + count),
      weight: _weight,
      hits: _hits,
      misses: _misses,
      evictions: _evictions,
      expirations: _expirations,
      persistentHits: _persistentHits,
      persistentMisses: _persistentMisses,
      byKind: byKind,
    );
  }

  Future<T> getOrLoad<T extends Object>({
    required ResourceCacheKey key,
    required Future<T> Function() loader,
    required ResourceCacheWeight<T> weightOf,
    bool forceRefresh = false,
  }) => _getOrLoad<T>(
        key: key,
        loader: loader,
        weightOf: weightOf,
        forceRefresh: forceRefresh,
        allowPersistentRead: true,
      );

  /// Resolves immutable image bytes for presentation.
  ///
  /// Durable response files remain private to the byte store because it may
  /// trim them at any time. Presentation receives an owned byte snapshot, so
  /// a later cache eviction cannot invalidate an already-created ImageProvider.
  Future<EncodedResourceSource> getOrLoadEncodedImage({
    required ResourceCacheKey key,
    required Future<Uint8List> Function() loader,
    bool forceRefresh = false,
    bool awaitPersistence = true,
    ResourceCacheRetention retention = ResourceCacheRetention.transient,
  }) async {
    _requireOpen();
    if (key.kind != ResourceCacheKind.imageBytes) {
      throw ArgumentError.value(
        key.kind,
        'key.kind',
        'encoded image resources are only valid for image bytes',
      );
    }
    final bytes = await _getOrLoad<Uint8List>(
      key: key,
      loader: loader,
      weightOf: (value) => value.lengthInBytes,
      forceRefresh: forceRefresh,
      allowPersistentRead: awaitPersistence,
      awaitPersistence: awaitPersistence,
      persistenceRetention: retention,
    );
    return MemoryEncodedResourceSource(bytes);
  }

  /// Returns a warm encoded image without invoking a loader.
  ///
  /// This is intentionally a probe rather than a miss-producing variant of
  /// [getOrLoadEncodedImage]. It lets a caller check a source-independent
  /// cache alias before resolving an optional source/plugin.
  Future<EncodedResourceSource?> getEncodedImageIfPresent(
    ResourceCacheKey key, {
    bool awaitPersistence = true,
    ResourceCacheRetention retention = ResourceCacheRetention.transient,
  }) async {
    _requireOpen();
    if (key.kind != ResourceCacheKind.imageBytes) {
      throw ArgumentError.value(
        key.kind,
        'key.kind',
        'encoded image resources are only valid for image bytes',
      );
    }
    _notePersistenceRetention(key, retention);
    final memory = _read<Uint8List>(key);
    if (memory != null) {
      _hits++;
      return MemoryEncodedResourceSource(memory);
    }
    final pending = _inFlight[key];
    if (pending != null) {
      _hits++;
      final value = await pending;
      if (value is Uint8List) {
        return MemoryEncodedResourceSource(value);
      }
      return null;
    }
    if (!awaitPersistence) {
      return null;
    }
    final persisted = await _readPersistent(key);
    if (persisted == null) {
      _persistentMisses++;
      return null;
    }
    final bytes = persisted.bytes;
    final policy = _policies[key.kind]!;
    final memoryExpiresAt = persisted.expiresAt ?? _now().add(policy.ttl);
    if (bytes.lengthInBytes <= policy.maxWeight &&
        bytes.lengthInBytes <= globalMaxWeight) {
      _storeWithExpiry(key, bytes, bytes.lengthInBytes, memoryExpiresAt);
    }
    _hits++;
    _persistentHits++;
    return MemoryEncodedResourceSource(
      bytes,
      origin: EncodedResourceOrigin.durableCacheFile,
    );
  }

  Future<T> _getOrLoad<T extends Object>({
    required ResourceCacheKey key,
    required Future<T> Function() loader,
    required ResourceCacheWeight<T> weightOf,
    required bool forceRefresh,
    required bool allowPersistentRead,
    bool awaitPersistence = true,
    ResourceCacheRetention? persistenceRetention,
  }) {
    _requireOpen();
    if (!forceRefresh && persistenceRetention != null) {
      _notePersistenceRetention(key, persistenceRetention);
    }
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
      if (persistenceRetention != null) {
        _notePersistenceRetention(key, persistenceRetention);
      }
    }

    _misses++;
    final generation = _generationOf(key);
    final epoch = _epoch;
    _activeLoads[key] = (_activeLoads[key] ?? 0) + 1;
    final future = _resolveLoad<T>(
      key: key,
      loader: loader,
      weightOf: weightOf,
      generation: generation,
      epoch: epoch,
      allowPersistentRead: !forceRefresh && allowPersistentRead,
      awaitPersistence: awaitPersistence,
    );
    final Future<Object> shared = future;
    _inFlight[key] = shared;
    return future.whenComplete(() {
      if (identical(_inFlight[key], shared)) {
        _inFlight.remove(key);
      }
      _finishLoad(key);
    });
  }

  Future<T> _resolveLoad<T extends Object>({
    required ResourceCacheKey key,
    required Future<T> Function() loader,
    required ResourceCacheWeight<T> weightOf,
    required int generation,
    required int epoch,
    required bool allowPersistentRead,
    required bool awaitPersistence,
  }) async {
    if (allowPersistentRead &&
        byteStore != null &&
        key.kind == ResourceCacheKind.imageBytes) {
      final persisted = await _readPersistent(key);
      if (persisted != null &&
          !_closed &&
          epoch == _epoch &&
          generation == _generationOf(key)) {
        final bytes = persisted.bytes;
        if (bytes is T) {
          final value = bytes as T;
          final weight = weightOf(value);
          final policy = _policies[key.kind]!;
          final memoryExpiresAt = persisted.expiresAt ?? _now().add(policy.ttl);
          if (weight >= 0 &&
              weight <= policy.maxWeight &&
              weight <= globalMaxWeight) {
            _storeWithExpiry(key, value, weight, memoryExpiresAt);
          }
          _hits++;
          _persistentHits++;
          return value;
        }
      }
      _persistentMisses++;
    }

    final value = await Future<T>.sync(loader);
    if (_closed || epoch != _epoch || generation != _generationOf(key)) {
      return value;
    }
    final weight = weightOf(value);
    if (weight < 0) {
      throw StateError('cache weight must not be negative for $key');
    }
    final policy = _policies[key.kind]!;
    if (weight <= policy.maxWeight && weight <= globalMaxWeight) {
      final expiresAt = _now().add(policy.ttl);
      _storeWithExpiry(key, value, weight, expiresAt);
      if (key.kind == ResourceCacheKind.imageBytes && value is Uint8List) {
        final persistence = _writePersistent(key, value, expiresAt);
        if (awaitPersistence) {
          await persistence;
        } else {
          unawaited(persistence);
        }
      }
    }
    return value;
  }

  T? peek<T extends Object>(ResourceCacheKey key) {
    _requireOpen();
    return _read<T>(key);
  }

  void invalidate(ResourceCacheKey key) {
    _requireOpen();
    _invalidateLocal(key);
    _queuePersistenceMutation(() async {
      await byteStore?.remove(key);
    });
  }

  void invalidateKind(ResourceCacheKind kind) {
    _requireOpen();
    _invalidateWhereLocal((key) => key.kind == kind);
    _queuePersistenceMutation(() async {
      await byteStore?.removeWhere((key) => key.kind == kind);
    });
  }

  void invalidateNamespace(String namespace) {
    _requireOpen();
    if (namespace.isEmpty) {
      return;
    }
    _invalidateWhereLocal((key) => key.namespace == namespace);
    _queuePersistenceMutation(() async {
      await byteStore?.removeWhere((key) => key.namespace == namespace);
    });
  }

  void invalidateWhere(bool Function(ResourceCacheKey key) predicate) {
    _requireOpen();
    _invalidateWhereLocal(predicate);
    _queuePersistenceMutation(() async {
      await byteStore?.removeWhere(predicate);
    });
  }

  void _invalidateWhereLocal(bool Function(ResourceCacheKey key) predicate) {
    final keys = <ResourceCacheKey>{
      ..._entries.keys,
      ..._inFlight.keys,
      ..._retainedPersistence,
    }.where(predicate).toList(growable: false);
    for (final key in keys) {
      _invalidateLocal(key);
    }
  }

  void _invalidateLocal(ResourceCacheKey key) {
    _generations[key] = _generationOf(key) + 1;
    _inFlight.remove(key);
    _removeEntry(key);
    _retainedPersistence.remove(key);
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
    _requireOpen();
    _epoch++;
    _entries.clear();
    _inFlight.clear();
    _generations.clear();
    _retainedPersistence.clear();
    _weight = 0;
    _queuePersistenceMutation(() async {
      await byteStore?.clear();
    });
  }

  Future<ResourceCacheByteStoreUsage?> inspectPersistentBytes() async {
    _requireOpen();
    await _persistenceTail;
    final store = byteStore;
    if (store is! ResourceCacheByteStoreMaintenance) {
      return null;
    }
    final maintenance = store as ResourceCacheByteStoreMaintenance;
    try {
      return await maintenance.inspect();
    } on Object catch (error, stackTrace) {
      _reportPersistenceError(error, stackTrace);
      return null;
    }
  }

  Future<ResourceCacheByteStoreTrimReport?> trimPersistentBytesTo({
    required int targetBytes,
  }) async {
    _requireOpen();
    if (targetBytes < 0) {
      throw ArgumentError.value(targetBytes, 'targetBytes');
    }
    await _persistenceTail;
    final store = byteStore;
    if (store is! ResourceCacheByteStoreMaintenance) {
      return null;
    }
    final maintenance = store as ResourceCacheByteStoreMaintenance;
    try {
      return await maintenance.trimTo(targetBytes: targetBytes);
    } on Object catch (error, stackTrace) {
      _reportPersistenceError(error, stackTrace);
      return null;
    }
  }

  Future<void> drainPersistence() {
    _requireOpen();
    return _persistenceTail;
  }

  Future<void> close() => _closeFuture ??= _performClose();

  Future<void> _performClose() async {
    // Stop accepting new work, but let already-owned requests reach their
    // normal cache/store commit point before closing the durable store.
    final pending = <Future<Object>>[..._inFlight.values];
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
    await _persistenceTail;
    try {
      await byteStore?.close();
    } on Object catch (error, stackTrace) {
      _reportPersistenceError(error, stackTrace);
    } finally {
      _closed = true;
      _epoch++;
      _entries.clear();
      _inFlight.clear();
      _generations.clear();
      _activeLoads.clear();
      _retainedPersistence.clear();
      _weight = 0;
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

  void _storeWithExpiry(
    ResourceCacheKey key,
    Object value,
    int weight,
    DateTime expiresAt,
  ) {
    _removeEntry(key);
    _entries[key] = _ResourceCacheEntry(
      value: value,
      weight: weight,
      touched: ++_clock,
      expiresAt: expiresAt,
    );
    _weight += weight;
    _enforceBudgets(key.kind, protectedKey: key);
  }

  Future<PersistedResourceBytes?> _readPersistent(ResourceCacheKey key) async {
    final store = byteStore;
    if (store == null) {
      return null;
    }
    await _persistenceTail;
    try {
      final persisted = await store.read(key);
      if (persisted == null) {
        return null;
      }
      final expiresAt = persisted.expiresAt;
      if (expiresAt != null && !expiresAt.isAfter(_now())) {
        _expirations++;
        _queuePersistenceMutation(() => store.remove(key));
        return null;
      }
      return persisted;
    } on Object catch (error, stackTrace) {
      _reportPersistenceError(error, stackTrace);
      return null;
    }
  }

  Future<void> _writePersistent(
    ResourceCacheKey key,
    Uint8List bytes,
    DateTime expiresAt,
  ) => _queuePersistenceMutation(() async {
          final retention = _persistenceRetentionFor(key);
          await byteStore?.write(
            key: key,
            bytes: bytes,
            expiresAt: retention == ResourceCacheRetention.retained
                ? null
                : expiresAt,
            retention: retention,
          );
  });

  ResourceCacheRetention _persistenceRetentionFor(ResourceCacheKey key) =>
      _retainedPersistence.contains(key)
          ? ResourceCacheRetention.retained
          : ResourceCacheRetention.transient;

  void _notePersistenceRetention(
    ResourceCacheKey key,
    ResourceCacheRetention retention,
  ) {
    if (retention != ResourceCacheRetention.retained ||
        !_retainedPersistence.add(key)) {
      return;
    }
    _queuePersistenceMutation(() async {
      await byteStore?.retain(key);
    });
  }

  Future<void> _queuePersistenceMutation(Future<void> Function() mutation) {
    if (byteStore == null) {
      return Future<void>.value();
    }
    final next = _persistenceTail.then((_) async {
      try {
        await mutation();
      } on Object catch (error, stackTrace) {
        _reportPersistenceError(error, stackTrace);
      }
    });
    _persistenceTail = next;
    return next;
  }

  void _reportPersistenceError(Object error, StackTrace stackTrace) {
    try {
      onPersistenceError?.call(error, stackTrace);
    } on Object {
      // Cache diagnostics must not make a source response fail.
    }
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
    if (_closed || _closeFuture != null) {
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
