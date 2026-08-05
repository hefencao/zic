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
  const PersistedResourceBytes({
    required this.bytes,
    required this.expiresAt,
  });

  final Uint8List bytes;
  final DateTime expiresAt;
}

/// Immutable encoded resource presented either from Dart memory or from an
/// already-durable file.
///
/// File-backed values let Flutter/native decoders open the cache artifact
/// directly instead of forcing every warm-start cover through
/// `File.readAsBytes`, a Dart-heap copy, and then another codec input copy.
enum EncodedResourceOrigin {
  memory,
  localFile,
  durableCacheFile,
}

sealed class EncodedResourceSource {
  const EncodedResourceSource({
    required this.origin,
    this.lengthInBytes,
  });

  final EncodedResourceOrigin origin;
  final int? lengthInBytes;
}

final class MemoryEncodedResourceSource extends EncodedResourceSource {
  MemoryEncodedResourceSource(this.bytes)
      : super(
          origin: EncodedResourceOrigin.memory,
          lengthInBytes: bytes.lengthInBytes,
        );

  final Uint8List bytes;
}

final class FileEncodedResourceSource extends EncodedResourceSource {
  const FileEncodedResourceSource({
    required this.path,
    EncodedResourceOrigin origin = EncodedResourceOrigin.durableCacheFile,
    super.lengthInBytes,
  })  : assert(path != ''),
        super(origin: origin);

  final String path;
}

/// Exact durable file location for one immutable response-cache entry.
///
/// The store has already validated the full cache key, expiry and file length.
/// Consumers must treat the path as read-only and must not retain it after the
/// owning cache entry is invalidated.
final class PersistedResourceFile {
  const PersistedResourceFile({
    required this.path,
    required this.byteLength,
    required this.expiresAt,
  })  : assert(path != ''),
        assert(byteLength >= 0);

  final String path;
  final int byteLength;
  final DateTime expiresAt;
}

/// Physical usage reported by an inspectable durable response-byte store.
final class ResourceCacheByteStoreUsage {
  const ResourceCacheByteStoreUsage({
    required this.bytes,
    required this.entries,
  })  : assert(bytes >= 0),
        assert(entries >= 0);

  final int bytes;
  final int entries;
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
/// The base store remains dependency-light; coordinators inspect and trim only
/// implementations that explicitly expose this capability.
abstract interface class ResourceCacheByteStoreMaintenance {
  Future<ResourceCacheByteStoreUsage> inspect();

  Future<ResourceCacheByteStoreTrimReport> trimTo({
    required int targetBytes,
  });
}

/// Optional fast path for stores whose encoded bytes already live in a stable
/// immutable file.
///
/// This capability deliberately sits beside [ResourceCacheByteStore] rather
/// than changing its byte API. Existing non-file stores remain valid, while
/// image presentation can avoid materializing warm entries in the Dart heap.
abstract interface class ResourceCacheByteStoreFileAccess {
  Future<PersistedResourceFile?> locate(ResourceCacheKey key);
}

/// Durable byte store whose entries can also be opened as stable files.
///
/// Dart cannot promote one nullable object to the intersection of two
/// unrelated interfaces after an `is` check. This explicit composition keeps
/// the capability honest and lets consumers use both read/write invalidation
/// and file-location operations without casts.
abstract interface class ResourceCacheFileByteStore
    implements ResourceCacheByteStore, ResourceCacheByteStoreFileAccess {}

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
    required DateTime expiresAt,
  });

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
  final Map<ResourceCacheKey, _FileResourceEntry> _fileEntries =
      <ResourceCacheKey, _FileResourceEntry>{};
  final Map<ResourceCacheKey, Future<Object>> _inFlight =
      <ResourceCacheKey, Future<Object>>{};
  final Map<ResourceCacheKey, Future<EncodedResourceSource>>
      _encodedImageInFlight =
      <ResourceCacheKey, Future<EncodedResourceSource>>{};
  final Map<ResourceCacheKey, int> _generations = <ResourceCacheKey, int>{};
  final Map<ResourceCacheKey, int> _activeLoads = <ResourceCacheKey, int>{};

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
      inFlight: _activeLoads.values.fold<int>(
        0,
        (sum, count) => sum + count,
      ),
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
  }) =>
      _getOrLoad<T>(
        key: key,
        loader: loader,
        weightOf: weightOf,
        forceRefresh: forceRefresh,
        allowPersistentRead: true,
      );

  /// Resolves immutable image bytes without forcing a durable file hit through
  /// `readAsBytes` when the backing store exposes file access.
  ///
  /// When [awaitPersistence] is false, a cold image load returns a
  /// [MemoryEncodedResourceSource] as soon as the source bytes are available.
  /// The durable write remains owned by this manager and is drained by
  /// [drainPersistence] and [close]. Warm durable files keep their normal
  /// file-backed fast path.
  Future<EncodedResourceSource> getOrLoadEncodedImage({
    required ResourceCacheKey key,
    required Future<Uint8List> Function() loader,
    bool forceRefresh = false,
    bool awaitPersistence = true,
  }) {
    _requireOpen();
    if (key.kind != ResourceCacheKind.imageBytes) {
      throw ArgumentError.value(
        key.kind,
        'key.kind',
        'file-backed encoded resources are only valid for image bytes',
      );
    }
    if (forceRefresh) {
      invalidate(key);
    } else {
      final warmFile = _readFileSource(key);
      if (warmFile != null) {
        _hits++;
        return Future<EncodedResourceSource>.value(warmFile);
      }
      final memory = _read<Uint8List>(key);
      if (memory != null) {
        _hits++;
        return Future<EncodedResourceSource>.value(
          MemoryEncodedResourceSource(memory),
        );
      }
      final pending = _encodedImageInFlight[key];
      if (pending != null) {
        _hits++;
        return pending;
      }
    }

    final future = _resolveEncodedImage(
      key: key,
      loader: loader,
      awaitPersistence: awaitPersistence,
    );
    _encodedImageInFlight[key] = future;
    return future.whenComplete(() {
      if (identical(_encodedImageInFlight[key], future)) {
        _encodedImageInFlight.remove(key);
      }
    });
  }

  /// Returns a warm encoded image without invoking a loader.
  ///
  /// This is intentionally a probe rather than a miss-producing variant of
  /// [getOrLoadEncodedImage]. It lets a caller check a source-independent
  /// cache alias before resolving an optional source/plugin.
  Future<EncodedResourceSource?> getEncodedImageIfPresent(
    ResourceCacheKey key, {
    bool awaitPersistence = true,
  }) async {
    _requireOpen();
    if (key.kind != ResourceCacheKind.imageBytes) {
      throw ArgumentError.value(
        key.kind,
        'key.kind',
        'file-backed encoded resources are only valid for image bytes',
      );
    }
    final warmFile = _readFileSource(key);
    if (warmFile != null) {
      _hits++;
      return warmFile;
    }
    final memory = _read<Uint8List>(key);
    if (memory != null) {
      _hits++;
      return MemoryEncodedResourceSource(memory);
    }
    final pending = _encodedImageInFlight[key];
    if (pending != null) {
      _hits++;
      return pending;
    }

    final file = await _locatePersistentFile(
      key,
      waitForPersistence: awaitPersistence,
    );
    if (file != null) {
      _hits++;
      _persistentHits++;
      final source = FileEncodedResourceSource(
        path: file.path,
        lengthInBytes: file.byteLength,
      );
      _storeFileSource(key, source, file.expiresAt);
      return source;
    }
    if (!awaitPersistence) {
      return null;
    }
    final persisted = await _readPersistent(key);
    if (persisted == null) {
      return null;
    }
    final bytes = persisted.bytes;
    final policy = _policies[key.kind]!;
    if (bytes.lengthInBytes <= policy.maxWeight &&
        bytes.lengthInBytes <= globalMaxWeight) {
      _storeWithExpiry(
        key,
        bytes,
        bytes.lengthInBytes,
        persisted.expiresAt,
      );
    }
    _hits++;
    _persistentHits++;
    return MemoryEncodedResourceSource(bytes);
  }

  Future<EncodedResourceSource> _resolveEncodedImage({
    required ResourceCacheKey key,
    required Future<Uint8List> Function() loader,
    required bool awaitPersistence,
  }) async {
    final file = await _locatePersistentFile(
      key,
      waitForPersistence: awaitPersistence,
    );
    if (file != null) {
      _hits++;
      _persistentHits++;
      final source = FileEncodedResourceSource(
        path: file.path,
        lengthInBytes: file.byteLength,
      );
      _storeFileSource(key, source, file.expiresAt);
      return source;
    }
    if (byteStore is ResourceCacheByteStoreFileAccess) {
      _persistentMisses++;
    }

    final bytes = await _getOrLoad<Uint8List>(
      key: key,
      loader: loader,
      weightOf: (value) => value.lengthInBytes,
      forceRefresh: false,
      // A file-capable store has already been checked without copying. Do not
      // immediately fall back to its legacy full-byte read path on a miss.
      allowPersistentRead: awaitPersistence &&
          byteStore is! ResourceCacheByteStoreFileAccess,
      awaitPersistence: awaitPersistence,
    );
    if (!awaitPersistence) {
      return MemoryEncodedResourceSource(bytes);
    }
    final persisted = await _locatePersistentFile(key);
    if (persisted != null) {
      final source = FileEncodedResourceSource(
        path: persisted.path,
        lengthInBytes: persisted.byteLength,
      );
      _removeEntry(key);
      _storeFileSource(key, source, persisted.expiresAt);
      return source;
    }
    return MemoryEncodedResourceSource(bytes);
  }

  Future<T> _getOrLoad<T extends Object>({
    required ResourceCacheKey key,
    required Future<T> Function() loader,
    required ResourceCacheWeight<T> weightOf,
    required bool forceRefresh,
    required bool allowPersistentRead,
    bool awaitPersistence = true,
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
          if (weight >= 0 &&
              weight <= policy.maxWeight &&
              weight <= globalMaxWeight) {
            _storeWithExpiry(key, value, weight, persisted.expiresAt);
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
      ..._fileEntries.keys,
      ..._inFlight.keys,
      ..._encodedImageInFlight.keys,
    }.where(predicate).toList(growable: false);
    for (final key in keys) {
      _invalidateLocal(key);
    }
  }

  void _invalidateLocal(ResourceCacheKey key) {
    _generations[key] = _generationOf(key) + 1;
    _inFlight.remove(key);
    _encodedImageInFlight.remove(key);
    _fileEntries.remove(key);
    _removeEntry(key);
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
    _fileEntries.clear();
    _inFlight.clear();
    _encodedImageInFlight.clear();
    _generations.clear();
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
    final pending = <Future<Object>>[
      ..._inFlight.values,
      ..._encodedImageInFlight.values,
    ];
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
      _fileEntries.clear();
      _inFlight.clear();
      _encodedImageInFlight.clear();
      _generations.clear();
      _activeLoads.clear();
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

  FileEncodedResourceSource? _readFileSource(ResourceCacheKey key) {
    final entry = _fileEntries[key];
    if (entry == null) {
      return null;
    }
    if (!entry.expiresAt.isAfter(_now())) {
      _fileEntries.remove(key);
      _expirations++;
      return null;
    }
    entry.touched = ++_clock;
    return entry.source;
  }

  void _storeFileSource(
    ResourceCacheKey key,
    FileEncodedResourceSource source,
    DateTime expiresAt,
  ) {
    _fileEntries[key] = _FileResourceEntry(
      source: source,
      touched: ++_clock,
      expiresAt: expiresAt,
    );
    final limit = _policies[ResourceCacheKind.imageBytes]!.maxEntries;
    while (_fileEntries.length > limit) {
      final victim = _fileEntries.entries.reduce(
        (left, right) =>
            left.value.touched <= right.value.touched ? left : right,
      );
      _fileEntries.remove(victim.key);
    }
  }

  Future<PersistedResourceBytes?> _readPersistent(
    ResourceCacheKey key,
  ) async {
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
      if (!persisted.expiresAt.isAfter(_now())) {
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

  Future<PersistedResourceFile?> _locatePersistentFile(
    ResourceCacheKey key, {
    bool waitForPersistence = true,
  }) async {
    final store = byteStore;
    if (store is! ResourceCacheFileByteStore) {
      return null;
    }
    final generation = _generationOf(key);
    final epoch = _epoch;
    if (waitForPersistence) {
      await _persistenceTail;
    }
    try {
      final file = await store.locate(key);
      if (file == null ||
          _closed ||
          epoch != _epoch ||
          generation != _generationOf(key)) {
        return null;
      }
      if (!file.expiresAt.isAfter(_now())) {
        _expirations++;
        _queuePersistenceMutation(() => store.remove(key));
        return null;
      }
      return file;
    } on Object catch (error, stackTrace) {
      _reportPersistenceError(error, stackTrace);
      return null;
    }
  }

  Future<void> _writePersistent(
    ResourceCacheKey key,
    Uint8List bytes,
    DateTime expiresAt,
  ) =>
      _queuePersistenceMutation(
        () async {
          await byteStore?.write(
            key: key,
            bytes: bytes,
            expiresAt: expiresAt,
          );
        },
      );

  Future<void> _queuePersistenceMutation(
    Future<void> Function() mutation,
  ) {
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
    for (final entry in _fileEntries.entries.toList(growable: false)) {
      if (!entry.value.expiresAt.isAfter(now)) {
        _fileEntries.remove(entry.key);
        _expirations++;
      }
    }
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

final class _FileResourceEntry {
  _FileResourceEntry({
    required this.source,
    required this.touched,
    required this.expiresAt,
  });

  final FileEncodedResourceSource source;
  int touched;
  final DateTime expiresAt;
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
