import 'dart:typed_data';

import 'package:domain/domain.dart';

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
