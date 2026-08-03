import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'artifact_cache_store.dart';
import 'promoted_artifact_byte_cache.dart';

/// Composition-owned multi-level router for immutable Reader page artifacts.
///
/// This manager owns tier ordering, exact identity/length presence checks,
/// complete-file read joining, hot-byte retention and write-through. Storage
/// backends only implement durable/in-memory artifact primitives; they do not
/// decide cache policy or duplicate tier routing.
final class ArtifactCacheManager
    implements ArtifactCacheStore, ArtifactCacheStreamStore {
  ArtifactCacheManager({
    required this.backend,
    PromotedArtifactByteCache? memory,
  }) : _memory = memory ?? PromotedArtifactByteCache();

  final ArtifactCacheBackend backend;
  final PromotedArtifactByteCache _memory;

  int get memoryEntryCount => _memory.entryCount;
  int get memoryBytes => _memory.retainedBytes;

  Uint8List? lookupMemory(DownloadId id, {int? length}) =>
      _memory.lookup(id, length: length);

  Future<ArtifactCacheLookup?> lookup(DownloadId id) async {
    final memory = _memory.lookup(id);
    if (memory != null) {
      return ArtifactCacheLookup(
        id: id,
        entry: _memoryEntry(memory),
        tier: ArtifactCacheTier.memory,
      );
    }
    final persistent = await backend.openArtifactStream(id);
    if (persistent == null) return null;
    return ArtifactCacheLookup(
      id: id,
      entry: persistent,
      tier: ArtifactCacheTier.persistent,
    );
  }

  /// Answers exact-key read visibility across all tiers using one policy.
  Future<bool> contains({
    required DownloadId id,
    required int expectedLength,
  }) async {
    if (_memory.contains(id, length: expectedLength)) return true;
    return containsBackend(id: id, expectedLength: expectedLength);
  }

  /// Answers exact-key presence in the durable/backend tier.
  ///
  /// Handoff must use this method rather than [contains]: an L1 memory hit is
  /// readable but does not prove that the promoted artifact was written
  /// through to the backend.
  Future<bool> containsBackend({
    required DownloadId id,
    required int expectedLength,
  }) async {
    final entry = await backend.openArtifactStream(id);
    return entry != null && entry.length == expectedLength;
  }

  /// Materializes a resolved foreground entry and joins concurrent reads.
  Future<PromotedArtifactByteRead> readForegroundLookup(
    ArtifactCacheLookup lookup,
  ) async {
    if (lookup.tier == ArtifactCacheTier.memory) {
      final bytes = await lookup.entry.readAll!();
      return PromotedArtifactByteRead(
        bytes: bytes,
        memoryHit: true,
        joined: false,
      );
    }
    return _memory.read(
      id: lookup.id,
      length: lookup.entry.length,
      loader: lookup.entry.readAll ?? () => _collect(lookup.entry),
    );
  }

  Future<PromotedArtifactByteRead?> readForeground(DownloadId id) async {
    final resolved = await lookup(id);
    return resolved == null ? null : readForegroundLookup(resolved);
  }

  /// Joins/retains immutable bytes produced by the authoritative Reader
  /// session without routing around its DownloadSession ownership.
  Future<PromotedArtifactByteRead> readSessionArtifact({
    required DownloadId id,
    required int length,
    required Future<Uint8List> Function() loader,
  }) =>
      _memory.read(id: id, length: length, loader: loader);

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async =>
      (await lookup(id))?.entry;

  @override
  Future<Uint8List?> readArtifact(DownloadId id) async =>
      (await readForeground(id))?.bytes;

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    await backend.storePromotedArtifact(id: id, bytes: bytes);
    _memory.remember(id: id, bytes: bytes);
  }

  void remember({required DownloadId id, required Uint8List bytes}) =>
      _memory.remember(id: id, bytes: bytes);

  void invalidateMemory(DownloadId id) => _memory.invalidate(id);

  void clearMemory() => _memory.clear();

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
  });

  final DownloadId id;
  final ArtifactCacheStreamEntry entry;
  final ArtifactCacheTier tier;
}
