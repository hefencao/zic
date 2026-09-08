import 'package:domain/domain.dart';
import 'package:storage/storage.dart' show CacheRec;

import 'artifact_cache_manager.dart';
import 'reader_page_identity.dart';

typedef VerifiedPageReuseIdentityResolver = Future<String?> Function(
  PageAsset page,
);

/// Compact affine candidate plus the exact source-page indexes whose immutable
/// media identity was actually compared successfully.
final class VerifiedArtifactOffsetProof {
  VerifiedArtifactOffsetProof({
    required this.targetOffsetFromSource,
    required Iterable<int> verifiedSourceIndexes,
  }) : verifiedSourceIndexes = List<int>.unmodifiable(
          (verifiedSourceIndexes.toSet().toList()..sort()),
        );

  final int targetOffsetFromSource;
  final List<int> verifiedSourceIndexes;
}

/// Compact target-chapter -> verified source-version fallback resolver.
///
/// The target chapter builds one exact page locator index. Each verified
/// version relation contributes a source-manifest reference plus an affine
/// offset; source DownloadIds are materialized only for pages that are
/// actually queried. This removes the V×P DownloadId/hash/set edge expansion.
/// The current caller may still hydrate source manifests themselves; that is a
/// separate library-locator cost, not hidden by this resolver.
final class VerifiedArtifactReuseResolver {
  VerifiedArtifactReuseResolver({required this.targetChapter})
      : _targetIndexes = <_ExactPageLocator, int>{
          for (final page in targetChapter.pages)
            _ExactPageLocator(page.pageId, page.uri): page.index,
        };

  final ChapterManifest targetChapter;
  final Map<_ExactPageLocator, int> _targetIndexes;
  final List<_VerifiedOffsetSource> _sources = <_VerifiedOffsetSource>[];
  int _eligiblePageCount = 0;

  int get relationCount => _sources.length;
  int get eligiblePageCount => _eligiblePageCount;

  int addVerifiedOffset({
    required ChapterManifest sourceChapter,
    required int targetOffsetFromSource,
    required Iterable<int> verifiedSourceIndexes,
  }) {
    final verified = <int>{};
    for (final sourceIndex in verifiedSourceIndexes) {
      final targetIndex = sourceIndex + targetOffsetFromSource;
      if (sourceIndex < 0 || sourceIndex >= sourceChapter.pages.length ||
          targetIndex < 0 || targetIndex >= targetChapter.pages.length) {
        continue;
      }
      verified.add(sourceIndex);
    }
    if (verified.isEmpty) return 0;
    _sources.add(
      _VerifiedOffsetSource(
        chapter: sourceChapter,
        targetOffsetFromSource: targetOffsetFromSource,
        verifiedSourceIndexes: verified,
      ),
    );
    _eligiblePageCount += verified.length;
    return verified.length;
  }

  Iterable<DownloadId> resolve(DownloadId id) sync* {
    final chapter = targetChapter;
    if (id.content.sourceId != chapter.sourceId ||
        id.content.comicId != chapter.comicId ||
        id.content.chapterId != chapter.chapter.chapterId ||
        id.sourceRevision != chapter.chapter.sourceRevision) {
      return;
    }
    final targetIndex =
        _targetIndexes[_ExactPageLocator(id.content.pageId, id.canonicalUri)];
    if (targetIndex == null) return;
    for (final source in _sources) {
      final sourceIndex = targetIndex - source.targetOffsetFromSource;
      if (sourceIndex < 0 ||
          sourceIndex >= source.chapter.pages.length ||
          !source.verifiedSourceIndexes.contains(sourceIndex)) {
        continue;
      }
      yield readerPageDownloadId(
        source.chapter,
        source.chapter.pages[sourceIndex],
      );
    }
  }
}

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

  /// Proves one compact target-index offset without materializing page pairs.
  ///
  /// A direct source identity match is preferred. If opaque source locators do
  /// not expose one, the same bounded related-version anchor proof used by
  /// [matchResolvedRelated] is applied. The returned value is
  /// `targetIndex - sourceIndex`.
  static Future<VerifiedArtifactOffsetProof?> matchResolvedRelatedOffset({
    required ChapterManifest sourceChapter,
    required ChapterManifest targetChapter,
    required VerifiedPageReuseIdentityResolver resolveIdentity,
  }) async {
    final sourceByIdentity = _uniquePageIndexes(sourceChapter);
    final targetByIdentity = _uniquePageIndexes(targetChapter);
    final directOffsets = <int>{};
    final directVerifiedSourceIndexes = <int>[];
    for (final entry in targetByIdentity.entries) {
      final sourceIndex = sourceByIdentity[entry.key];
      if (sourceIndex == null) continue;
      directOffsets.add(entry.value - sourceIndex);
      if (directOffsets.length > 1) return null;
      directVerifiedSourceIndexes.add(sourceIndex);
    }
    if (directOffsets.isNotEmpty) {
      return VerifiedArtifactOffsetProof(
        targetOffsetFromSource: directOffsets.single,
        verifiedSourceIndexes: directVerifiedSourceIndexes,
      );
    }
    if (sourceChapter.pages.isEmpty || targetChapter.pages.isEmpty) return null;

    final sourcePages = sourceChapter.pages;
    final targetPages = targetChapter.pages;
    final shifts = <int>{
      sourcePages.length - targetPages.length,
      0,
    };
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
          : <int>[targetEnd - 1, targetStart];
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
      final verifiedSourceIndexes = <int>[];
      for (var index = 0; index < anchorTargets.length; index++) {
        final sourceIdentity = sourceIdentities[index];
        final targetIdentity = targetIdentities[index];
        if (sourceIdentity != null && sourceIdentity == targetIdentity) {
          verifiedSourceIndexes.add(anchorTargets[index] + shift);
        }
      }
      final required = anchorTargets.length == 1 ? 1 : 2;
      if (verifiedSourceIndexes.length < required) continue;
      return VerifiedArtifactOffsetProof(
        targetOffsetFromSource: -shift,
        verifiedSourceIndexes: verifiedSourceIndexes,
      );
    }
    return null;
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
    final proof = await matchResolvedRelatedOffset(
      sourceChapter: sourceChapter,
      targetChapter: targetChapter,
      resolveIdentity: resolveIdentity,
    );
    if (proof == null) return direct;
    return VerifiedArtifactReusePlan.fromVerifiedOffset(
      sourceChapter: sourceChapter,
      targetChapter: targetChapter,
      targetOffsetFromSource: proof.targetOffsetFromSource,
      verifiedSourceIndexes: proof.verifiedSourceIndexes,
    );
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
  }) => matchResolvedRelated(
        sourceChapter: oldChapter,
        targetChapter: newChapter,
        resolveIdentity: resolveIdentity,
      );

  /// Rebuilds a plan from a previously source-verified positional mapping.
  ///
  /// No source request, URL resolution or media identity lookup is performed.
  /// This is the cold-Reader path: expensive proof must have been persisted
  /// earlier by the detail/version background updater.
  factory VerifiedArtifactReusePlan.fromVerifiedOffset({
    required ChapterManifest sourceChapter,
    required ChapterManifest targetChapter,
    required int targetOffsetFromSource,
    required Iterable<int> verifiedSourceIndexes,
  }) {
    final sourcePages = sourceChapter.pages;
    final targetPages = targetChapter.pages;
    final mappings = <DownloadId, DownloadId>{};
    for (final sourceIndex in verifiedSourceIndexes.toSet()) {
      if (sourceIndex < 0 || sourceIndex >= sourcePages.length) continue;
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

  /// Materializes already-downloaded source artifacts under their verified
  /// target exact identities. This makes version migration reuse survive an
  /// app restart even when the source-version library records are removed.
  /// Missing source artifacts are skipped; only source-verified mappings are
  /// eligible.
  Future<int> materializeTargetArtifacts(ArtifactCacheManager cache) async {
    var materialized = 0;
    for (final mapping in mappings.entries) {
      if (await cache.materializeVerifiedEquivalentTarget(
        sourceId: mapping.value,
        targetId: mapping.key,
      )) {
        materialized++;
      }
    }
    return materialized;
  }
}

final class _VerifiedOffsetSource {
  const _VerifiedOffsetSource({
    required this.chapter,
    required this.targetOffsetFromSource,
    required this.verifiedSourceIndexes,
  });

  final ChapterManifest chapter;
  final int targetOffsetFromSource;
  final Set<int> verifiedSourceIndexes;
}

final class _ExactPageLocator {
  const _ExactPageLocator(this.pageId, this.uri);

  final String pageId;
  final Uri uri;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ExactPageLocator && pageId == other.pageId && uri == other.uri;

  @override
  int get hashCode => Object.hash(pageId, uri);
}


Map<String, int> _uniquePageIndexes(ChapterManifest chapter) {
  final candidates = <String, List<int>>{};
  for (final page in chapter.pages) {
    final identity = verifiedPageIdentity(page);
    if (identity == null) continue;
    candidates.putIfAbsent(identity, () => <int>[]).add(page.index);
  }
  return <String, int>{
    for (final entry in candidates.entries)
      if (entry.value.length == 1) entry.key: entry.value.single,
  };
}

Map<String, PageAsset> _uniquePages(ChapterManifest chapter) {
  final candidates = <String, List<PageAsset>>{};
  for (final page in chapter.pages) {
    final identity = verifiedPageIdentity(page);
    if (identity == null) continue;
    candidates.putIfAbsent(identity, () => <PageAsset>[]).add(page);
  }
  return <String, PageAsset>{
    for (final entry in candidates.entries)
      if (entry.value.length == 1) entry.key: entry.value.single,
  };
}

/// Computes all content-based verified identities for a page asset (checksum,
/// E-Hentai image key, and URI content hash).
Iterable<String> verifiedPageIdentities(PageAsset page) sync* {
  final checksum = page.checksum?.trim().toLowerCase();
  final algorithm = page.checksumAlgorithm?.trim().toLowerCase();
  // A digest without its algorithm is not a stable content identity: source
  // adapters have historically used the same field for MD5, SHA and opaque
  // provider tokens. Do not create a cross-version alias from an untyped
  // value ('checksum:$checksum'); strong URI/image identities below remain available.
  if (checksum != null && checksum.isNotEmpty &&
      algorithm != null && algorithm.isNotEmpty) {
    yield 'checksum:$algorithm:$checksum';
  }
  final segments = page.uri.pathSegments;
  final marker = segments.indexOf('s');
  if (marker >= 0 && marker + 1 < segments.length) {
    final imageKey = segments[marker + 1].trim().toLowerCase();
    if (imageKey.isNotEmpty) {
      yield 'eh:$imageKey';
    }
  }
  final hash = RegExp(r'[a-fA-F0-9]{32,64}')
      .firstMatch(page.uri.toString())
      ?.group(0)
      ?.toLowerCase();
  if (hash != null) {
    yield 'hash:$hash';
  }
}

/// Primary verified identity for a page asset.
String? verifiedPageIdentity(PageAsset page) =>
    verifiedPageIdentities(page).firstOrNull;

/// Computes all content-based verified identities for an indexed cache record.
Iterable<String> verifiedRecordIdentities(CacheRec record) sync* {
  final checksum = record.checksum.trim().toLowerCase();
  final algorithm = record.checksumAlgorithm.trim().toLowerCase();
  if (checksum.isNotEmpty && algorithm.isNotEmpty) {
    yield 'checksum:$algorithm:$checksum';
  }
  final uri = record.id.canonicalUri;
  final segments = uri.pathSegments;
  final marker = segments.indexOf('s');
  if (marker >= 0 && marker + 1 < segments.length) {
    final imageKey = segments[marker + 1].trim().toLowerCase();
    if (imageKey.isNotEmpty) {
      yield 'eh:$imageKey';
    }
  }
  final hash = RegExp(r'[a-fA-F0-9]{32,64}')
      .firstMatch(uri.toString())
      ?.group(0)
      ?.toLowerCase();
  if (hash != null) {
    yield 'hash:$hash';
  }
}

/// Primary verified identity for a cache record.
String? verifiedRecordIdentity(CacheRec record) =>
    verifiedRecordIdentities(record).firstOrNull;
