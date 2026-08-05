import 'package:domain/domain.dart';

import 'artifact_cache_manager.dart';
import 'reader_page_identity.dart';

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
