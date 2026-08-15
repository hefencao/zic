import 'package:domain/domain.dart';

import 'artifact_cache_manager.dart';
import 'reader_page_identity.dart';

typedef VerifiedPageReuseIdentityResolver = Future<String?> Function(
  PageAsset page,
);

/// Verified page-artifact reuse between two explicitly related comic versions.
///
/// The planner never uses title, author, sequence or raw page index alone. A
/// page is reusable only when both manifests expose the same unique checksum,
/// E-Hentai `/s/<image-key>/...` identity, or a unique 32–64 digit content
/// hash in the resolved URI. This is the conservative portion of
/// VibeVenera's version-cache migration model.
final class VerifiedArtifactReusePlan {
  VerifiedArtifactReusePlan._(Map<DownloadId, DownloadId> mappings)
      : mappings = Map<DownloadId, DownloadId>.unmodifiable(mappings);

  factory VerifiedArtifactReusePlan.match({
    required ChapterManifest oldChapter,
    required ChapterManifest newChapter,
  }) {
    final oldByIdentity = _uniquePages(oldChapter);
    final newByIdentity = _uniquePages(newChapter);
    final mappings = <DownloadId, DownloadId>{};
    for (final entry in newByIdentity.entries) {
      final oldPage = oldByIdentity[entry.key];
      if (oldPage == null) continue;
      mappings[
        readerPageDownloadId(newChapter, entry.value)
      ] = readerPageDownloadId(oldChapter, oldPage);
    }
    return VerifiedArtifactReusePlan._(mappings);
  }

  /// Builds a target-version -> source-version verified page mapping for two
  /// source-confirmed related versions, independent of version direction.
  ///
  /// [sourceChapter] is the side whose existing artifact may be reused;
  /// [targetChapter] is the side currently being opened. Page-count delta is
  /// evidence for an edge insertion/removal on either side, not an ordering
  /// rule: a newer cached version may therefore satisfy an older target too.
  static Future<VerifiedArtifactReusePlan> matchResolvedRelated({
    required ChapterManifest sourceChapter,
    required ChapterManifest targetChapter,
    required VerifiedPageReuseIdentityResolver resolveIdentity,
  }) async {
    final direct = VerifiedArtifactReusePlan.match(
      oldChapter: sourceChapter,
      newChapter: targetChapter,
    );
    if (direct.mappings.isNotEmpty ||
        sourceChapter.pages.isEmpty ||
        targetChapter.pages.isEmpty) {
      return direct;
    }

    final sourcePages = sourceChapter.pages;
    final targetPages = targetChapter.pages;
    final shifts = <int>[
      sourcePages.length - targetPages.length,
      0,
    ].toSet();
    for (final shift in shifts) {
      final targetStart = shift < 0 ? -shift : 0;
      final targetEndCandidate = sourcePages.length - shift;
      final targetEnd = targetEndCandidate < targetPages.length
          ? targetEndCandidate
          : targetPages.length;
      if (targetStart >= targetEnd) continue;
      final overlap = targetEnd - targetStart;
      final anchorTargets = overlap == 1
          ? <int>[targetStart]
          : <int>{
              targetStart,
              targetStart + overlap ~/ 2,
              targetEnd - 1,
            }.toList(growable: false);
      final sourceIdentities = await Future.wait(
        anchorTargets.map(
          (targetIndex) =>
              resolveIdentity(sourcePages[targetIndex + shift]),
        ),
      );
      if (sourceIdentities.any((identity) => identity == null)) continue;
      final targetIdentities = await Future.wait(
        anchorTargets.map((index) => resolveIdentity(targetPages[index])),
      );
      var matches = 0;
      for (var index = 0; index < anchorTargets.length; index++) {
        final sourceIdentity = sourceIdentities[index];
        final targetIdentity = targetIdentities[index];
        if (sourceIdentity != null && sourceIdentity == targetIdentity) {
          matches++;
        }
      }
      final required = anchorTargets.length == 1 ? 1 : 2;
      if (matches < required) continue;
      return VerifiedArtifactReusePlan._(<DownloadId, DownloadId>{
        for (var targetIndex = targetStart;
            targetIndex < targetEnd;
            targetIndex++)
          readerPageDownloadId(targetChapter, targetPages[targetIndex]):
              readerPageDownloadId(
                sourceChapter,
                sourcePages[targetIndex + shift],
              ),
      });
    }
    return direct;
  }

  /// Builds a new-version -> old-version verified page mapping without
  /// migrating any durable library state.
  ///
  /// Some sources (notably Venera/E-Hentai) expose opaque page locators in the
  /// chapter manifest, so the direct stable identity is unavailable until the
  /// source-owned request plan is resolved. This follows VibeVenera's bounded
  /// version-reuse rule: prove a stable positional offset using first/middle/
  /// last resolved media identities, then map the corresponding exact page
  /// DownloadIds. The proof is registered as symmetric cache equivalence.
  static Future<VerifiedArtifactReusePlan> matchResolvedOffset({
    required ChapterManifest oldChapter,
    required ChapterManifest newChapter,
    required VerifiedPageReuseIdentityResolver resolveIdentity,
  }) async {
    final direct = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );
    if (direct.mappings.isNotEmpty ||
        oldChapter.pages.isEmpty ||
        newChapter.pages.length < oldChapter.pages.length) {
      return direct;
    }

    final oldPages = oldChapter.pages;
    final newPages = newChapter.pages;
    final anchors = oldPages.length == 1
        ? const <int>[0]
        : <int>{0, oldPages.length ~/ 2, oldPages.length - 1}.toList();
    final oldIdentities = await Future.wait(
      anchors.map((index) => resolveIdentity(oldPages[index])),
    );
    if (oldIdentities.any((identity) => identity == null)) return direct;

    final delta = newPages.length - oldPages.length;
    final offsets = <int>{delta, 0}.where(
      (offset) => offset >= 0 && oldPages.length + offset <= newPages.length,
    );
    for (final offset in offsets) {
      final newIdentities = await Future.wait(
        anchors.map((index) => resolveIdentity(newPages[index + offset])),
      );
      var matches = 0;
      for (var index = 0; index < anchors.length; index++) {
        final oldIdentity = oldIdentities[index];
        final newIdentity = newIdentities[index];
        if (oldIdentity != null && oldIdentity == newIdentity) matches++;
      }
      final required = anchors.length == 1 ? 1 : 2;
      if (matches < required) continue;
      return VerifiedArtifactReusePlan._(<DownloadId, DownloadId>{
        for (var index = 0; index < oldPages.length; index++)
          readerPageDownloadId(newChapter, newPages[index + offset]):
              readerPageDownloadId(oldChapter, oldPages[index]),
      });
    }
    return direct;
  }

  /// Rebuilds a plan from a previously source-verified positional mapping.
  ///
  /// No source request, URL resolution or media identity lookup is performed.
  /// This is the cold-Reader path: expensive proof must have been persisted
  /// earlier by the detail/version background updater.
  factory VerifiedArtifactReusePlan.fromVerifiedOffset({
    required ChapterManifest sourceChapter,
    required ChapterManifest targetChapter,
    required int targetOffsetFromSource,
  }) {
    final sourcePages = sourceChapter.pages;
    final targetPages = targetChapter.pages;
    final mappings = <DownloadId, DownloadId>{};
    for (var sourceIndex = 0; sourceIndex < sourcePages.length; sourceIndex++) {
      final targetIndex = sourceIndex + targetOffsetFromSource;
      if (targetIndex < 0 || targetIndex >= targetPages.length) continue;
      mappings[
        readerPageDownloadId(targetChapter, targetPages[targetIndex])
      ] = readerPageDownloadId(sourceChapter, sourcePages[sourceIndex]);
    }
    return VerifiedArtifactReusePlan._(mappings);
  }

  /// Target exact identity -> source exact identity verified as the same media.
  final Map<DownloadId, DownloadId> mappings;

  /// Registers verified page pairs as symmetric lookup fallbacks.
  ///
  /// Registration does not require either artifact to exist yet. Exact writes
  /// stay exact, while a later promoted artifact on either version can satisfy
  /// the other version's subsequent lookup. This is the durable-mapping
  /// counterpart of VibeVenera's temporary image-key mapping, without turning
  /// the artifact backend into a second cache or redirecting durable writes.
  int registerEquivalences(ArtifactCacheManager cache) {
    for (final entry in mappings.entries) {
      cache.linkEquivalent(first: entry.key, second: entry.value);
    }
    return mappings.length;
  }

}

Map<String, PageAsset> _uniquePages(ChapterManifest chapter) {
  final candidates = <String, List<PageAsset>>{};
  for (final page in chapter.pages) {
    final identity = _verifiedPageIdentity(page);
    if (identity == null) continue;
    candidates.putIfAbsent(identity, () => <PageAsset>[]).add(page);
  }
  return <String, PageAsset>{
    for (final entry in candidates.entries)
      if (entry.value.length == 1) entry.key: entry.value.single,
  };
}

String? _verifiedPageIdentity(PageAsset page) {
  final checksum = page.checksum?.trim().toLowerCase();
  if (checksum != null && checksum.isNotEmpty) {
    return 'checksum:$checksum';
  }
  final segments = page.uri.pathSegments;
  final marker = segments.indexOf('s');
  if (marker >= 0 && marker + 1 < segments.length) {
    final imageKey = segments[marker + 1].trim().toLowerCase();
    if (imageKey.isNotEmpty) return 'eh:$imageKey';
  }
  final hash = RegExp(r'[a-fA-F0-9]{32,64}')
      .firstMatch(page.uri.toString())
      ?.group(0)
      ?.toLowerCase();
  return hash == null ? null : 'hash:$hash';
}
