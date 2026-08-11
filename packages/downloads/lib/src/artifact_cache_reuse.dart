import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'partial_download_store.dart';
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
  VerifiedArtifactReusePlan._(Map<DownloadId, DownloadId> aliases)
      : aliases = Map<DownloadId, DownloadId>.unmodifiable(aliases);

  factory VerifiedArtifactReusePlan.match({
    required ChapterManifest oldChapter,
    required ChapterManifest newChapter,
  }) {
    final oldByIdentity = _uniquePages(oldChapter);
    final newByIdentity = _uniquePages(newChapter);
    final aliases = <DownloadId, DownloadId>{};
    for (final entry in newByIdentity.entries) {
      final oldPage = oldByIdentity[entry.key];
      if (oldPage == null) continue;
      aliases[
        readerPageDownloadId(newChapter, entry.value)
      ] = readerPageDownloadId(oldChapter, oldPage);
    }
    return VerifiedArtifactReusePlan._(aliases);
  }

  /// Builds a temporary target-version -> source-version alias map for two
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
    if (direct.aliases.isNotEmpty ||
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

  /// Builds a temporary new-version -> old-version alias map without
  /// migrating any durable library state.
  ///
  /// Some sources (notably Venera/E-Hentai) expose opaque page locators in the
  /// chapter manifest, so the direct stable identity is unavailable until the
  /// source-owned request plan is resolved. This follows VibeVenera's bounded
  /// version-reuse rule: prove a stable positional offset using first/middle/
  /// last resolved media identities, then alias the corresponding exact page
  /// DownloadIds. The alias remains in ArtifactCacheManager memory only.
  static Future<VerifiedArtifactReusePlan> matchResolvedOffset({
    required ChapterManifest oldChapter,
    required ChapterManifest newChapter,
    required VerifiedPageReuseIdentityResolver resolveIdentity,
  }) async {
    final direct = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );
    if (direct.aliases.isNotEmpty ||
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
    final aliases = <DownloadId, DownloadId>{};
    for (var sourceIndex = 0; sourceIndex < sourcePages.length; sourceIndex++) {
      final targetIndex = sourceIndex + targetOffsetFromSource;
      if (targetIndex < 0 || targetIndex >= targetPages.length) continue;
      aliases[
        readerPageDownloadId(targetChapter, targetPages[targetIndex])
      ] = readerPageDownloadId(sourceChapter, sourcePages[sourceIndex]);
    }
    return VerifiedArtifactReusePlan._(aliases);
  }

  /// New exact artifact identity -> old authoritative artifact identity.
  final Map<DownloadId, DownloadId> aliases;

  int apply(ArtifactCacheManager cache) {
    for (final entry in aliases.entries) {
      cache.alias(id: entry.key, target: entry.value);
    }
    return aliases.length;
  }

  /// Registers aliases only when the old authoritative artifact exists.
  ///
  /// This matches the VibeVenera reuse boundary: page equivalence alone does
  /// not fabricate a cache hit. A missing old artifact remains a normal miss
  /// for the new exact identity.
  Future<int> applyExisting(ArtifactCacheManager cache) async {
    var applied = 0;
    for (final entry in aliases.entries) {
      final source = await cache.lookup(entry.value);
      if (source == null) continue;
      final targetStorage = cache.resolveAlias(entry.key);
      if (targetStorage == source.storageId) {
        applied++;
        continue;
      }
      if (await cache.lookup(entry.key) != null) continue;
      cache.alias(id: entry.key, target: source.storageId);
      applied++;
    }
    return applied;
  }

  /// Reuses only durable, inactive partial prefixes for verified page pairs.
  ///
  /// Cross-version ETag/Last-Modified values are deliberately discarded. The
  /// target DownloadJob therefore resumes with its existing validatorless
  /// overlap probe and compares response bytes against the preserved prefix
  /// before accepting any continuation. Hot Reader sessions are excluded by
  /// [PartialDownloadStore.openPartialDownload].
  Future<int> applyDurablePartials(PartialDownloadStore store) async {
    var applied = 0;
    for (final entry in aliases.entries) {
      if (await store.openPartialDownload(entry.key) != null) continue;
      final source = await store.openPartialDownload(entry.value);
      if (source == null || source.length <= 0) continue;
      await store.storePartialDownload(
        id: entry.key,
        entry: PartialDownloadEntry(
          length: source.length,
          validators: const Validators(),
          totalLength: source.totalLength,
          open: source.open,
        ),
      );
      applied++;
    }
    return applied;
  }

  /// Physically migrates every artifact that currently exists.
  ///
  /// Use this after the application has committed the newer comic version as
  /// authoritative. Missing old artifacts are skipped; no network request is
  /// triggered by the migration itself.
  Future<int> rekeyExisting(ArtifactCacheManager cache) async {
    var migrated = 0;
    for (final entry in aliases.entries) {
      if (await cache.rekey(oldId: entry.value, newId: entry.key)) {
        migrated++;
      }
    }
    return migrated;
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
