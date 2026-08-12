import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'artifact_cache_store.dart';

/// Composition-owned multi-level router for immutable Reader page artifacts.
final class ArtifactCacheManager {
  ArtifactCacheManager({
    required this.backend,
    this.memoryMaxEntries = 10,
    this.memoryMaxBytes = 256 * 1024 * 1024,
    this.equivalenceMaxEntries = 8192,
  })  : assert(memoryMaxEntries > 0),
        assert(memoryMaxBytes > 0),
        assert(equivalenceMaxEntries > 0);

  final ArtifactCacheBackend backend;
  final int memoryMaxEntries;
  final int memoryMaxBytes;
  final int equivalenceMaxEntries;
  final LinkedHashMap<_ArtifactByteKey, Uint8List> _memory =
      LinkedHashMap<_ArtifactByteKey, Uint8List>();
  final Map<_ArtifactByteKey, Future<Uint8List>> _inFlight =
      <_ArtifactByteKey, Future<Uint8List>>{};
  final Set<_ArtifactByteKey> _durableMemory = <_ArtifactByteKey>{};
  final LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>> _equivalents =
      LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>>();
  final LinkedHashSet<_ArtifactEquivalencePair> _equivalenceOrder =
      LinkedHashSet<_ArtifactEquivalencePair>();
  int _memoryBytes = 0;

  int get memoryEntryCount => _memory.length;
  int get memoryBytes => _memoryBytes;
  int get equivalenceCount => _equivalenceOrder.length;

  Iterable<DownloadId> directEquivalents(DownloadId id) =>
      List<DownloadId>.unmodifiable(
        _equivalents[id] ?? const <DownloadId>{},
      );

  /// Registers a source-verified immutable-artifact equivalence.
  ///
  /// Equivalence is a lookup fallback, never a storage redirect. Both exact
  /// identities remain authoritative for writes. A later
  /// artifact promoted under either version therefore becomes immediately
  /// reusable by the other version without creating a directed alias cycle.
  void linkEquivalent({
    required DownloadId first,
    required DownloadId second,
  }) {
    if (first == second) return;
    final pair = _ArtifactEquivalencePair(first, second);
    _equivalenceOrder.remove(pair);
    _equivalenceOrder.add(pair);
    _equivalents
        .putIfAbsent(first, () => LinkedHashSet<DownloadId>())
        .add(second);
    _equivalents
        .putIfAbsent(second, () => LinkedHashSet<DownloadId>())
        .add(first);
    while (_equivalenceOrder.length > equivalenceMaxEntries) {
      final oldest = _equivalenceOrder.first;
      _equivalenceOrder.remove(oldest);
      _removeEquivalentEdge(oldest.first, oldest.second);
      _removeEquivalentEdge(oldest.second, oldest.first);
    }
  }

  void _removeEquivalentEdge(DownloadId first, DownloadId second) {
    final values = _equivalents[first];
    if (values == null) return;
    values.remove(second);
    if (values.isEmpty) _equivalents.remove(first);
  }

  Iterable<DownloadId> _lookupCandidates(DownloadId id) sync* {
    yield id;
    final equivalents = _equivalents[id];
    if (equivalents == null) return;
    for (final equivalent in equivalents) {
      if (equivalent != id) yield equivalent;
    }
  }

  Uint8List? lookupMemory(DownloadId id, {int? length}) {
    for (final candidate in _lookupCandidates(id)) {
      final bytes = _lookupMemoryExact(candidate, length: length);
      if (bytes != null) return bytes;
    }
    return null;
  }

  Uint8List? _lookupMemoryExact(DownloadId id, {int? length}) {
    _ArtifactByteKey? selected;
    for (final key in _memory.keys.toList(growable: false).reversed) {
      if (key.id == id && (length == null || key.length == length)) {
        selected = key;
        break;
      }
    }
    if (selected == null) return null;
    final bytes = _memory.remove(selected);
    if (bytes == null) return null;
    if (bytes.isEmpty) {
      _durableMemory.remove(selected);
      return null;
    }
    _memory[selected] = bytes;
    return bytes;
  }

  Future<ArtifactCacheLookup?> lookup(DownloadId id) =>
      _lookupCandidatesInOrder(id, _lookupCandidates(id));

  /// Looks up only this exact identity's authoritative durable storage.
  ///
  /// Verified equivalence is intentionally excluded. Promotion and other
  /// durable ownership checks must not mistake a related version's artifact
  /// for this exact DownloadId's own persisted artifact.
  Future<ArtifactCacheLookup?> lookupAuthoritative(DownloadId id) =>
      _lookupCandidatesInOrder(id, <DownloadId>[id]);

  Future<ArtifactCacheLookup?> _lookupCandidatesInOrder(
    DownloadId id,
    Iterable<DownloadId> candidates,
  ) async {
    for (final storageId in candidates) {
      final memory = _lookupMemoryExact(storageId);
      if (memory != null) {
        final key = _ArtifactByteKey(storageId, memory.lengthInBytes);
        return ArtifactCacheLookup(
          id: id,
          storageId: storageId,
          entry: _memoryEntry(memory),
          tier: ArtifactCacheTier.memory,
          durable: _durableMemory.contains(key),
        );
      }
      final entry = await backend.openArtifactStream(storageId);
      if (entry == null) continue;
      if (entry.length <= 0) {
        await backend.invalidateArtifact(storageId);
        continue;
      }
      return ArtifactCacheLookup(
        id: id,
        storageId: storageId,
        entry: entry,
        tier: ArtifactCacheTier.persistent,
        durable: true,
      );
    }
    return null;
  }

  Future<bool> contains({
    required DownloadId id,
    required int expectedLength,
  }) async {
    final lookup = await this.lookup(id);
    return lookup != null && lookup.entry.length == expectedLength;
  }

  Future<bool> containsBackendExact({
    required DownloadId id,
    required int expectedLength,
  }) async {
    final entry = await backend.openArtifactStream(id);
    return entry != null && entry.length == expectedLength;
  }

  Future<ArtifactCacheRead> readForegroundLookup(
    ArtifactCacheLookup lookup,
  ) async {
    if (lookup.tier == ArtifactCacheTier.memory) {
      return ArtifactCacheRead(
        bytes: await lookup.entry.readAll!(),
        memoryHit: true,
        joined: false,
        durable: lookup.durable,
      );
    }
    return _readJoined(
      id: lookup.storageId,
      length: lookup.entry.length,
      durable: true,
      loader: lookup.entry.readAll ?? () => _collect(lookup.entry),
    );
  }

  Future<ArtifactCacheRead?> readForeground(DownloadId id) async {
    final lookup = await this.lookup(id);
    return lookup == null ? null : readForegroundLookup(lookup);
  }

  Future<ArtifactCacheRead> readSessionArtifact({
    required DownloadId id,
    required int length,
    required Future<Uint8List> Function() loader,
  }) => _readJoined(
        id: id,
        length: length,
        durable: false,
        loader: loader,
      );

  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      throw StateError('cannot store an empty promoted artifact for ${id.key}');
    }
    await backend.storePromotedArtifact(id: id, bytes: bytes);
    remember(id: id, bytes: bytes, durable: true);
  }

  void remember({
    required DownloadId id,
    required Uint8List bytes,
    bool durable = false,
  }) {
    if (bytes.isEmpty) {
      invalidateMemory(id);
      return;
    }
    final key = _ArtifactByteKey(id, bytes.lengthInBytes);
    for (final stale in _memory.keys
        .where((candidate) => candidate.id == id && candidate != key)
        .toList(growable: false)) {
      final removed = _memory.remove(stale);
      _durableMemory.remove(stale);
      if (removed != null) _memoryBytes -= removed.lengthInBytes;
    }
    final previous = _memory.remove(key);
    final wasDurable = _durableMemory.remove(key);
    if (previous != null) _memoryBytes -= previous.lengthInBytes;
    if (bytes.lengthInBytes > memoryMaxBytes) return;
    _memory[key] = bytes;
    if (durable || wasDurable) _durableMemory.add(key);
    _memoryBytes += bytes.lengthInBytes;
    while (_memory.length > memoryMaxEntries || _memoryBytes > memoryMaxBytes) {
      final oldest = _memory.keys.first;
      _durableMemory.remove(oldest);
      _memoryBytes -= _memory.remove(oldest)!.lengthInBytes;
    }
  }

  void invalidateMemory(DownloadId id) {
    _invalidateMemoryExact(id);
  }

  void _invalidateMemoryExact(DownloadId id) {
    for (final key in _memory.keys
        .where((candidate) => candidate.id == id)
        .toList(growable: false)) {
      final removed = _memory.remove(key);
      _durableMemory.remove(key);
      if (removed != null) _memoryBytes -= removed.lengthInBytes;
    }
  }

  Future<void> invalidate(DownloadId id) async {
    _invalidateMemoryExact(id);
    await backend.invalidateArtifact(id);
  }

  void clearMemory() {
    _memory.clear();
    _durableMemory.clear();
    _equivalents.clear();
    _equivalenceOrder.clear();
    _memoryBytes = 0;
  }

  Future<ArtifactCacheRead> _readJoined({
    required DownloadId id,
    required int length,
    required bool durable,
    required Future<Uint8List> Function() loader,
  }) async {
    if (length <= 0) {
      await invalidate(id);
      throw StateError('artifact cache entry is empty for ${id.key}');
    }
    final cached = _lookupMemoryExact(id, length: length);
    if (cached != null) {
      return ArtifactCacheRead(
        bytes: cached,
        memoryHit: true,
        joined: false,
        durable: _durableMemory.contains(_ArtifactByteKey(id, length)),
      );
    }
    final key = _ArtifactByteKey(id, length);
    final running = _inFlight[key];
    if (running != null) {
      final bytes = await running;
      if (durable) {
        remember(id: id, bytes: bytes, durable: true);
      }
      return ArtifactCacheRead(
        bytes: bytes,
        memoryHit: false,
        joined: true,
        durable: _durableMemory.contains(key),
      );
    }
    late final Future<Uint8List> tracked;
    tracked = Future<Uint8List>.sync(loader).then<Uint8List>((bytes) async {
      if (bytes.isEmpty || bytes.lengthInBytes != length) {
        await invalidate(id);
        throw StateError(
          bytes.isEmpty
              ? 'artifact cache body is empty for ${id.key}'
              : 'artifact cache length changed while reading: '
                  '${bytes.lengthInBytes}/$length for ${id.key}',
        );
      }
      remember(id: id, bytes: bytes, durable: durable);
      return bytes;
    }).whenComplete(() {
      if (identical(_inFlight[key], tracked)) _inFlight.remove(key);
    });
    _inFlight[key] = tracked;
    return ArtifactCacheRead(
      bytes: await tracked,
      memoryHit: false,
      joined: false,
      durable: durable,
    );
  }

  static ArtifactCacheStreamEntry _memoryEntry(Uint8List bytes) =>
      ArtifactCacheStreamEntry(
        length: bytes.lengthInBytes,
        open: ({required int start, int? endExclusive}) async* {
          final end = (endExclusive ?? bytes.lengthInBytes)
              .clamp(start, bytes.lengthInBytes)
              .toInt();
          for (var offset = start;
              offset < end;
              offset += promotedArtifactReadChunkBytes) {
            final chunkEnd = (offset + promotedArtifactReadChunkBytes)
                .clamp(offset, end)
                .toInt();
            yield Uint8List.sublistView(bytes, offset, chunkEnd);
          }
        },
        readAll: () async => bytes,
      );

  static Future<Uint8List> _collect(ArtifactCacheStreamEntry entry) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in entry.open(start: 0)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.lengthInBytes != entry.length) {
      throw StateError(
        'artifact cache entry length changed while reading: '
        '${bytes.lengthInBytes}/${entry.length}',
      );
    }
    return bytes;
  }
}

enum ArtifactCacheTier { memory, persistent }

final class ArtifactCacheLookup {
  const ArtifactCacheLookup({
    required this.id,
    DownloadId? storageId,
    required this.entry,
    required this.tier,
    this.durable = false,
  }) : storageId = storageId ?? id;

  /// Identity requested by the caller.
  final DownloadId id;

  /// Exact authoritative artifact used after alias resolution.
  final DownloadId storageId;
  final ArtifactCacheStreamEntry entry;
  final ArtifactCacheTier tier;
  final bool durable;
}

final class ArtifactCacheRead {
  const ArtifactCacheRead({
    required this.bytes,
    required this.memoryHit,
    required this.joined,
    this.durable = false,
  });

  final Uint8List bytes;
  final bool memoryHit;
  final bool joined;
  final bool durable;
}

final class _ArtifactEquivalencePair {
  const _ArtifactEquivalencePair(this.first, this.second);

  final DownloadId first;
  final DownloadId second;

  @override
  bool operator ==(Object other) =>
      other is _ArtifactEquivalencePair &&
      ((other.first == first && other.second == second) ||
          (other.first == second && other.second == first));

  @override
  int get hashCode => first.hashCode ^ second.hashCode;
}

final class _ArtifactByteKey {
  const _ArtifactByteKey(this.id, this.length);
  final DownloadId id;
  final int length;

  @override
  bool operator ==(Object other) =>
      other is _ArtifactByteKey && other.id == id && other.length == length;

  @override
  int get hashCode => Object.hash(id, length);
}
