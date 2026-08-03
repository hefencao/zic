import 'dart:typed_data';

import 'package:domain/domain.dart';

/// Local promoted artifacts are read in 1 MiB chunks so the session ingress
/// does not pay dozens of Dart stream wakeups for a single large WebP. Network
/// transports retain their independent 256 KiB chunk contract.
const int promotedArtifactReadChunkBytes = 1024 * 1024;

/// Read/write handoff for completed encoded page artifacts.
///
/// Pipeline and DownloadSession remain authoritative while a page is active.
/// Implementations only expose already-promoted bytes and accept a completed
/// promoted artifact after the owning session has sealed it. They must not
/// create a competing download, decode or presentation policy.
abstract interface class ArtifactCacheStore {
  Future<Uint8List?> readArtifact(DownloadId id);

  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  });
}

/// Immutable promoted artifact entry that can be streamed without first
/// materializing the complete encoded page in Dart memory.
final class ArtifactCacheStreamEntry {
  const ArtifactCacheStreamEntry({
    required this.length,
    required this.open,
    this.readAll,
  });

  final int length;
  final Stream<List<int>> Function({
    required int start,
    int? endExclusive,
  }) open;

  /// Optional optimized complete-file read used only for foreground pages.
  /// Implementations should avoid repeated async chunk dispatch and return
  /// immutable bytes owned by the caller/cache.
  final Future<Uint8List> Function()? readAll;
}

/// Optional persistent-store capability used by Reader DownloadSession.
///
/// The returned stream is still consumed by the authoritative session; this
/// capability only removes the redundant full-file Uint8List handoff.
abstract interface class ArtifactCacheStreamStore {
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id);
}
