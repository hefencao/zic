import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'artifact_cache_store.dart';

/// Composition-owned multi-level router for immutable Reader page artifacts.
final class ArtifactCacheManager {
  ArtifactCacheManager({
    required this.backend,
    this.memoryMaxEntries = 4,
    this.memoryMaxBytes = 96 * 1024 * 1024,
  })  : assert(memoryMaxEntries > 0),
        assert(memoryMaxBytes > 0);

  final ArtifactCacheBackend backend;
  final int memoryMaxEntries;
  final int memoryMaxBytes;
  final LinkedHashMap<_ArtifactByteKey, Uint8List> _memory =
      LinkedHashMap<_ArtifactByteKey, Uint8List>();
  final Map<_ArtifactByteKey, Future<Uint8List>> _inFlight =
      <_ArtifactByteKey, Future<Uint8List>>{};
  final Set<_ArtifactByteKey> _durableMemory = <_ArtifactByteKey>{};
  int _memoryBytes = 0;

  int get memoryEntryCount => _memory.length;
  int get memoryBytes => _memoryBytes;

  Uint8List? lookupMemory(DownloadId id, {int? length}) {
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
    _memory[selected] = bytes;
    return bytes;
  }

  Future<ArtifactCacheLookup?> lookup(DownloadId id) async {
    final memory = lookupMemory(id);
    if (memory != null) {
      final key = _ArtifactByteKey(id, memory.lengthInBytes);
      return ArtifactCacheLookup(
        id: id,
        entry: _memoryEntry(memory),
        tier: ArtifactCacheTier.memory,
        durable: _durableMemory.contains(key),
      );
    }
    final entry = await backend.openArtifactStream(id);
    if (entry == null) return null;
    return ArtifactCacheLookup(
      id: id,
      entry: entry,
      tier: ArtifactCacheTier.persistent,
      durable: true,
    );
  }

  Future<bool> contains({
    required DownloadId id,
    required int expectedLength,
  }) async {
    if (lookupMemory(id, length: expectedLength) != null) return true;
    return containsBackend(id: id, expectedLength: expectedLength);
  }

  Future<bool> containsBackend({
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
      id: lookup.id,
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
    await backend.storePromotedArtifact(id: id, bytes: bytes);
    remember(id: id, bytes: bytes, durable: true);
  }

  void remember({
    required DownloadId id,
    required Uint8List bytes,
    bool durable = false,
  }) {
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
    for (final key in _memory.keys
        .where((candidate) => candidate.id == id)
        .toList(growable: false)) {
      final removed = _memory.remove(key);
      _durableMemory.remove(key);
      if (removed != null) _memoryBytes -= removed.lengthInBytes;
    }
  }

  void clearMemory() {
    _memory.clear();
    _durableMemory.clear();
    _memoryBytes = 0;
  }

  Future<ArtifactCacheRead> _readJoined({
    required DownloadId id,
    required int length,
    required bool durable,
    required Future<Uint8List> Function() loader,
  }) async {
    final cached = lookupMemory(id, length: length);
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
    tracked = Future<Uint8List>.sync(loader).then((bytes) {
      if (bytes.lengthInBytes != length) {
        throw StateError(
          'artifact cache length changed while reading: '
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
    required this.entry,
    required this.tier,
    this.durable = false,
  });

  final DownloadId id;
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
