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
abstract interface class PhysicalArtifactCacheBackend {
  /// Opens one immutable artifact by its version-independent physical identity.
  /// No exact DownloadId carrier lookup is permitted inside this operation.
  Future<ArtifactCacheStreamEntry?> openPhysicalArtifact(PhysicalMediaId id);

  /// Adds a physical-media binding to an already-authoritative exact artifact.
  /// The backend must not copy bytes or rewrite the immutable object.
  Future<bool> bindPhysicalArtifact({
    required PhysicalMediaId physicalId,
    required DownloadId sourceId,
  });

  Future<void> invalidatePhysicalArtifact(PhysicalMediaId id);
}

/// Optional compatibility bridge for durable READY artifacts written before a
/// stable physical-media binding existed, or before a provider URI changed.
///
/// The caller supplies only already-authorized exact/direct candidates. The
/// backend may use an indexed logical-page lookup to bind an existing immutable
/// artifact to [physicalId], but must not scan unrelated cache rows or infer
/// version equivalence itself.
abstract interface class PhysicalArtifactCandidateBindingBackend {
  Future<bool> bindPhysicalArtifactFromCandidates({
    required PhysicalMediaId physicalId,
    required Iterable<DownloadId> candidates,
  });
}

/// Optional zero-copy bridge from canonical physical ownership back to one
/// exact logical download identity.
///
/// The physical artifact is already the immutable byte authority. A manual
/// download only needs an exact durable binding/pin; it must not manufacture a
/// second artifact object merely because the historical exact provider row was
/// retired. Implementations must revalidate [physicalId] before binding
/// [targetId] to that same object.
abstract interface class PhysicalArtifactExactBindingBackend {
  Future<bool> bindExactArtifactFromPhysical({
    required PhysicalMediaId physicalId,
    required DownloadId targetId,
  });
}

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

/// Optional exact-binding retention query used by presentation recovery.
///
/// A force reload may reject bytes for presentation without revoking the
/// user's explicit offline-download intent. Backends exposing this capability
/// report only the exact binding's retention flag; they do not choose reload
/// policy or physical-media ownership.
abstract interface class ArtifactCacheRetentionQuery {
  Future<bool> isPinnedExactArtifact(DownloadId id);
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
