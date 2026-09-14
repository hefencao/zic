part of 'chapter_downloads.dart';

final class _ArtifactPromotionRecovery {
  static Future<void> _recoverPendingArtifactPromotions(
    SqliteIndex index,
  ) async {
    for (final promotion in await index.listArtifactPromotions()) {
      if (await _promotionFileMatches(
        promotion.destinationAccessLocator,
        promotion,
      )) {
        await index.commitArtifactPromotion(promotion.promotionKey);
        await _deleteStalePromotionSource(promotion);
        continue;
      }
      final sourceMatches = await _promotionFileMatches(
        promotion.sourceAccessLocator,
        promotion,
      );
      if (!sourceMatches) {
        await index.removeArtifactPromotion(promotion.promotionKey);
        continue;
      }
      final destinationType = await FileSystemEntity.type(
        promotion.destinationAccessLocator,
        followLinks: false,
      );
      if (destinationType != FileSystemEntityType.notFound) {
        // A different destination body is a collision, not a reason to let the
        // transaction journal seize that path. Roll back to the still-valid
        // partial authority and leave the foreign destination untouched.
        await index.removeArtifactPromotion(promotion.promotionKey);
        continue;
      }
      try {
        final destination = File(promotion.destinationAccessLocator);
        await destination.parent.create(recursive: true);
        await File(promotion.sourceAccessLocator).rename(destination.path);
      } on FileSystemException {
        // Keep the journal and source partial authoritative-progress facts.
        // A later open can retry; do not turn a transient filesystem failure
        // into body loss or sidecar-derived recovery.
        continue;
      }
      if (!await _promotionFileMatches(
        promotion.destinationAccessLocator,
        promotion,
      )) {
        // The rename completed but the bytes no longer match the sealed DB
        // proof. Keep the journal so both candidate locators stay protected;
        // ordinary structural diagnostics can surface the storage failure.
        continue;
      }
      await index.commitArtifactPromotion(promotion.promotionKey);
      await _deleteStalePromotionSource(promotion);
    }
  }

  static Future<bool> _promotionFileMatches(
    String path,
    ArtifactPromotionRecord promotion,
  ) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file) return false;
    final file = File(path);
    if (await file.length() != promotion.bytes) return false;
    if (promotion.checksumAlgorithm.trim().toLowerCase() != 'crc32') {
      return false;
    }
    final crc = Crc32();
    await for (final chunk in file.openRead()) {
      crc.add(chunk);
    }
    return crc.hex == promotion.checksum.trim().toLowerCase();
  }

  static Future<void> _deleteStalePromotionSource(
    ArtifactPromotionRecord promotion,
  ) async {
    if (promotion.sourceAccessLocator == promotion.destinationAccessLocator) {
      return;
    }
    for (final path in <String>[
      promotion.sourceAccessLocator,
      '${promotion.sourceAccessLocator}.meta',
      '${promotion.sourceAccessLocator}.meta.tmp',
    ]) {
      try {
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.file) {
          await File(path).delete();
        }
      } on FileSystemException {
        // Source cleanup is not part of the authority commit. The now-unowned
        // file remains eligible for ordinary bounded orphan cleanup.
      }
    }
  }

}
