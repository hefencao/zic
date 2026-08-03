import 'dart:typed_data';

import 'package:domain/domain.dart';

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
}
