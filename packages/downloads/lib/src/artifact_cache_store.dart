import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

const int promotedArtifactReadChunkBytes = 1024 * 1024;

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
  final Future<Uint8List> Function()? readAll;
}


/// Durable-but-incomplete page bytes kept separately from immutable promoted
/// artifacts. A partial is never a cache hit for final media; it can only seed
/// a DownloadSession before the authoritative transport resumes.
final class PartialArtifactCacheEntry {
  const PartialArtifactCacheEntry({
    required this.length,
    required this.validators,
    required this.open,
    this.totalLength,
  });

  final int length;
  final Validators validators;
  final int? totalLength;
  final Stream<List<int>> Function({required int start}) open;
}

/// Optional capability implemented by durable chapter storage.
///
/// Keeping this separate from [ArtifactCacheBackend] prevents an incomplete
/// prefix from ever being mistaken for an immutable ready artifact.
abstract interface class PartialArtifactCacheBackend {
  Future<PartialArtifactCacheEntry?> openPartialArtifact(DownloadId id);

  Future<void> storePartialArtifact({
    required DownloadId id,
    required PartialArtifactCacheEntry entry,
  });

  Future<void> invalidatePartialArtifact(DownloadId id);
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
