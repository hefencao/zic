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

abstract interface class ArtifactCacheBoundRangeReader {
  String get accessMode;

  Future<Uint8List> readRange(int start, int endExclusive);

  Future<void> close();
}

/// Engine-readable immutable encoded-file lease for one physical generation.
///
/// The path may be a normal file or a process-local descriptor path such as
/// `/proc/self/fd/<n>`. Callers must keep the lease alive while an engine
/// ImageProvider may reopen/read the path; [release] retires only this lease,
/// never the artifact's logical cache binding.
final class ArtifactCachePresentationFileLease {
  const ArtifactCachePresentationFileLease({
    required this.path,
    required this.length,
    required this.release,
    this.width,
    this.height,
  });

  final String path;
  final int length;
  final int? width;
  final int? height;
  final Future<void> Function() release;
}

typedef ArtifactCachePresentationFileOpener =
    Future<ArtifactCachePresentationFileLease?> Function();

/// Platform/storage adapter that can pin one physical locator behind an
/// engine-readable file path. Android uses descriptor-backed `/proc/self/fd`
/// leases for both Direct and SAF artifacts; tests/backends may omit it.
abstract interface class ArtifactPresentationFileLeaseFactory {
  Future<ArtifactCachePresentationFileLease?> open(
    String accessLocator, {
    required int expectedLength,
  });
}

final class ArtifactCacheStreamEntry {
  const ArtifactCacheStreamEntry({
    required this.length,
    required this.open,
    this.readAll,
    this.readAllControlled,
    this.openBoundRangeReader,
    this.openPresentationFile,
    this.accessMode = 'unknown',
    this.streamIntegrity = ArtifactReadIntegrityBasis.unspecified,
    this.fullReadIntegrity = ArtifactReadIntegrityBasis.unspecified,
  });

  final int length;
  final Stream<List<int>> Function({
    required int start,
    int? endExclusive,
  }) open;
  final Future<Uint8List> Function()? readAll;

  /// Optional generation-scoped random-access reader. Persistent backends may
  /// expose this after locator/replica preflight so a READY physical session
  /// can reuse one descriptor across decoder range requests.
  final Future<ArtifactCacheBoundRangeReader?> Function()? openBoundRangeReader;

  /// Optional engine-facing file/descriptor lease over the same immutable
  /// generation. This deliberately carries no Flutter types; presentation
  /// decides which codec/provider can consume the leased path.
  final ArtifactCachePresentationFileOpener? openPresentationFile;

  /// Non-sensitive diagnostics for the selected physical access path.
  final String accessMode;

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
abstract interface class ArtifactCacheBindingBackend {
  /// Adds [targetId] as another exact logical binding to [sourceId]'s existing
  /// immutable durable artifact. The caller owns semantic equivalence proof;
  /// the backend must revalidate source durability and must not copy body bytes.
  /// Returns false when zero-copy binding is not currently safe/available.
  Future<bool> bindExistingArtifact({
    required DownloadId sourceId,
    required DownloadId targetId,
  });
}

abstract interface class ArtifactCacheBackend {
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id);

  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  });

  /// Removes a proven-corrupt or stale artifact from this backend.
  Future<void> invalidateArtifact(DownloadId id);
}
