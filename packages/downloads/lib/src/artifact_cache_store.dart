import 'dart:typed_data';

import 'package:domain/domain.dart';

const int promotedArtifactReadChunkBytes = 1024 * 1024;

/// Integrity work actually performed by the byte source used for one read.
///
/// This is observation/proof metadata, never cache admission or retry policy.
/// `sealedMetadataLength` means the immutable artifact's seal/checksum proof
/// was established earlier and this access rechecked locator/existence/length
/// only; `crc32Verified` means this read itself recomputed the whole-file CRC.
enum ArtifactReadIntegrityBasis {
  unspecified,
  memoryResident,
  sealedMetadataLength,
  crc32Verified,
  sessionArtifact,
}

final class ArtifactCacheStreamEntry {
  const ArtifactCacheStreamEntry({
    required this.length,
    required this.open,
    this.readAll,
    this.readAllControlled,
    this.streamIntegrity = ArtifactReadIntegrityBasis.unspecified,
    this.fullReadIntegrity = ArtifactReadIntegrityBasis.unspecified,
  });

  final int length;
  final Stream<List<int>> Function({
    required int start,
    int? endExclusive,
  }) open;
  final Future<Uint8List> Function()? readAll;

  /// Integrity basis of [open]. A normal sealed persistent read should expose
  /// its previously-established seal proof rather than pretending to rehash.
  final ArtifactReadIntegrityBasis streamIntegrity;

  /// Integrity basis of [readAll]/[readAllControlled].
  final ArtifactReadIntegrityBasis fullReadIntegrity;

  /// Optional backend-owned full read that can abort its underlying stream
  /// from the caller's scheduler control. When absent, the manager may still
  /// stop awaiting [readAll], but the backend operation remains uncontrolled.
  final Future<Uint8List> Function({required TaskControl control})?
      readAllControlled;
}


/// Replaceable storage primitive behind the composition-owned cache manager.
///
/// Backends do not own tier order, presence policy, in-flight joining, hot-byte
/// retention or invalidation. Those rules belong to [ArtifactCacheManager].
abstract interface class ArtifactCacheBackend {
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id);

  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  });

  /// Removes a proven-corrupt or stale artifact from this backend.
  Future<void> invalidateArtifact(DownloadId id);
}
