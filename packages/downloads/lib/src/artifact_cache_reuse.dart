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
      if (await cache.lookup(entry.value) == null) continue;
      cache.alias(id: entry.key, target: entry.value);
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
