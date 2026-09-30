import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart' show CacheRec;

import 'artifact_cache_manager.dart';
import 'reader_page_identity.dart';

final RegExp _uriContentHashPattern = RegExp(r'[a-fA-F0-9]{32,64}');

typedef VerifiedPageReuseIdentityResolver =
    Future<String?> Function(PageAsset page);

String canonicalMediaExactChapterKey({
  required String sourceId,
  required String comicId,
  required String chapterId,
  required String sourceRevision,
}) =>
    '$sourceId\u0000$comicId\u0000$chapterId\u0000$sourceRevision';

String canonicalMediaExactChapterKeyForDownload(DownloadId id) =>
    canonicalMediaExactChapterKey(
      sourceId: id.content.sourceId,
      comicId: id.content.comicId,
      chapterId: id.content.chapterId,
      sourceRevision: id.sourceRevision,
    );

final class CanonicalMediaActiveRange {
  const CanonicalMediaActiveRange({
    required this.start,
    required this.endExclusive,
  })  : assert(start >= 0),
        assert(endExclusive > start);

  final int start;
  final int endExclusive;

  bool contains(int index) => index >= start && index < endExclusive;
}

/// Compact direct exact-chapter -> canonical physical-media authority.
///
/// One instance owns one hydrated manifest, not one row per page. Runtime
/// lookup validates [DownloadId.pageIndexHint] against the exact manifest slot
/// before consuming either a stable URI content identity or a persisted
/// canonical projection. An active family projection wins so mixed strong/
/// opaque provider locators still converge on one version-family physical
/// owner. Stable URI identity remains the direct fallback outside active
/// projection ranges; metadata-only checksum enrichment never owns a physical
/// key and therefore cannot rename a segment-backed owner.
final class CanonicalMediaChapterAuthority {
  CanonicalMediaChapterAuthority({
    required this.manifest,
    this.projection,
    Iterable<CanonicalMediaActiveRange> activeProjectionRanges =
        const <CanonicalMediaActiveRange>[],
  }) : exactKey = canonicalMediaExactChapterKey(
         sourceId: manifest.sourceId,
         comicId: manifest.comicId,
         chapterId: manifest.chapter.chapterId,
         sourceRevision: manifest.chapter.sourceRevision,
       ),
       activeProjectionRanges =
           List<CanonicalMediaActiveRange>.unmodifiable(
             _normalizeCanonicalMediaActiveRanges(activeProjectionRanges),
       ),
       _stablePhysicalMediaByPage =
           Map<int, PhysicalMediaId>.unmodifiable(
         <int, PhysicalMediaId>{
           for (final page in manifest.pages)
             if (verifiedPhysicalMediaId(
                   sourceId: manifest.sourceId,
                   page: page,
                 )
                 case final physical?)
               page.index: physical,
         },
           ) {
    final projection = this.projection;
    if (projection != null &&
        (projection.sourceId != manifest.sourceId ||
            projection.comicId != manifest.comicId ||
            projection.chapterId != manifest.chapter.chapterId ||
            projection.sourceRevision != manifest.chapter.sourceRevision ||
            projection.pageCount != manifest.pages.length)) {
      throw ArgumentError('canonical projection does not match manifest');
    }
  }

  final ChapterManifest manifest;
  final VersionChapterCanonicalProjection? projection;
  final List<CanonicalMediaActiveRange> activeProjectionRanges;
  final String exactKey;
  final Map<int, PhysicalMediaId> _stablePhysicalMediaByPage;

  bool get hasResolvablePhysicalMedia =>
      _stablePhysicalMediaByPage.isNotEmpty ||
      (projection != null && activeProjectionRanges.isNotEmpty);

  PhysicalMediaId? resolve(DownloadId id) {
    if (canonicalMediaExactChapterKeyForDownload(id) != exactKey) return null;
    final index = id.pageIndexHint;
    if (index == null || index < 0 || index >= manifest.pages.length) return null;
    final page = manifest.pages[index];
    if (page.index != index ||
        page.pageId != id.content.pageId ||
        page.uri != id.canonicalUri) {
      return null;
    }
    final projection = this.projection;
    if (projection != null &&
        activeProjectionRanges.any((range) => range.contains(index))) {
      final coordinate = projection.coordinateForPageIndexOrNull(index);
      if (coordinate != null) {
        return PhysicalMediaId.canonical(coordinate.stableKey);
      }
    }
    return _stablePhysicalMediaByPage[index];
  }
}

Map<String, List<CanonicalMediaActiveRange>>
    canonicalMediaActiveRangesFromRelations(
  Iterable<ComicVersionRelation> relations,
) {
  final ranges = <String, List<CanonicalMediaActiveRange>>{};

  void add(String exactKey, int start, int endExclusive) {
    if (start < 0 || endExclusive <= start) return;
    ranges
        .putIfAbsent(exactKey, () => <CanonicalMediaActiveRange>[])
        .add(
          CanonicalMediaActiveRange(start: start, endExclusive: endExclusive),
        );
  }

  for (final relation in relations) {
    for (final mapping in relation.pageMappings) {
      final predecessorRevision = mapping.predecessorSourceRevision;
      final successorRevision = mapping.successorSourceRevision;
      if (predecessorRevision == null || successorRevision == null) continue;
      final predecessorKey = canonicalMediaExactChapterKey(
        sourceId: relation.sourceId,
        comicId: relation.predecessorComicId,
        chapterId: mapping.predecessorChapterId,
        sourceRevision: predecessorRevision,
      );
      final successorKey = canonicalMediaExactChapterKey(
        sourceId: relation.sourceId,
        comicId: relation.successorComicId,
        chapterId: mapping.successorChapterId,
        sourceRevision: successorRevision,
      );
      for (final interval in mapping.effectiveVerifiedIntervals) {
        add(
          predecessorKey,
          interval.predecessorStart,
          interval.predecessorEndExclusive,
        );
        add(
          successorKey,
          interval.predecessorStart + interval.successorOffset,
          interval.predecessorEndExclusive + interval.successorOffset,
        );
      }
    }
  }

  return <String, List<CanonicalMediaActiveRange>>{
    for (final entry in ranges.entries)
      entry.key: List<CanonicalMediaActiveRange>.unmodifiable(
        _normalizeCanonicalMediaActiveRanges(entry.value),
      ),
  };
}

List<CanonicalMediaActiveRange> _normalizeCanonicalMediaActiveRanges(
  Iterable<CanonicalMediaActiveRange> values,
) {
  final ordered = values.toList()
    ..sort((left, right) => left.start.compareTo(right.start));
  final result = <CanonicalMediaActiveRange>[];
  for (final current in ordered) {
    if (result.isEmpty || current.start > result.last.endExclusive) {
      result.add(current);
      continue;
    }
    final previous = result.last;
    final end = current.endExclusive > previous.endExclusive
        ? current.endExclusive
        : previous.endExclusive;
    result[result.length - 1] = CanonicalMediaActiveRange(
      start: previous.start,
      endExclusive: end,
    );
  }
  return result;
}

/// Compact affine page mapping plus the bounded anchor indexes used to prove
/// that mapping. Once the offset is accepted, every page in the affine overlap
/// is eligible for the same temporary cache-alias semantics used by VibeVenera;
/// [verifiedSourceIndexes] are proof diagnostics, not a per-page allow-list.
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

final class VerifiedArtifactIntervalProof {
  VerifiedArtifactIntervalProof({
    required Iterable<VerifiedComicVersionPageInterval> verifiedIntervals,
    required Iterable<int> verifiedSourceIndexes,
    required this.probeCount,
  }) : verifiedIntervals = List<VerifiedComicVersionPageInterval>.unmodifiable(
         verifiedIntervals,
       ),
       verifiedSourceIndexes = List<int>.unmodifiable(
         (verifiedSourceIndexes.toSet().toList()..sort()),
       );

  final List<VerifiedComicVersionPageInterval> verifiedIntervals;
  final List<int> verifiedSourceIndexes;
  final int probeCount;
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
  VerifiedArtifactReuseResolver({required this.targetChapter});

  /// Builds the directional predecessor -> successor projection used by the
  /// composition-level direct reuse authority. The persisted mapping expresses
  /// `successorIndex = predecessorIndex + successorOffset`; this resolver is
  /// queried with predecessor ids and therefore uses the inverse affine view.
  factory VerifiedArtifactReuseResolver.predecessorToSuccessor({
    required ChapterManifest predecessorChapter,
    required ChapterManifest successorChapter,
    required Iterable<VerifiedComicVersionPageInterval> verifiedIntervals,
  }) {
    final resolver = VerifiedArtifactReuseResolver(
      targetChapter: predecessorChapter,
    );
    for (final interval in verifiedIntervals) {
      resolver.addVerifiedInterval(
        sourceChapter: successorChapter,
        sourceStart: interval.predecessorStart + interval.successorOffset,
        sourceEndExclusive:
            interval.predecessorEndExclusive + interval.successorOffset,
        targetOffsetFromSource: -interval.successorOffset,
      );
    }
    return resolver;
  }

  final ChapterManifest targetChapter;
  final List<_VerifiedOffsetSource> _sources = <_VerifiedOffsetSource>[];
  int _eligiblePageCount = 0;

  int get relationCount => _sources.length;
  int get eligiblePageCount => _eligiblePageCount;

  int addVerifiedInterval({
    required ChapterManifest sourceChapter,
    required int sourceStart,
    required int sourceEndExclusive,
    required int targetOffsetFromSource,
  }) {
    if (sourceStart < 0 ||
        sourceEndExclusive <= sourceStart ||
        sourceEndExclusive > sourceChapter.pages.length) {
      return 0;
    }
    final targetStart = sourceStart + targetOffsetFromSource;
    final targetEnd = sourceEndExclusive + targetOffsetFromSource;
    if (targetStart < 0 || targetEnd > targetChapter.pages.length) {
      return 0;
    }
    _sources.add(
      _VerifiedOffsetSource(
        chapter: sourceChapter,
        sourceStart: sourceStart,
        sourceEndExclusive: sourceEndExclusive,
        targetOffsetFromSource: targetOffsetFromSource,
      ),
    );
    final length = sourceEndExclusive - sourceStart;
    _eligiblePageCount += length;
    return length;
  }

  int addVerifiedOffset({
    required ChapterManifest sourceChapter,
    required int targetOffsetFromSource,
    required Iterable<int> verifiedSourceIndexes,
  }) {
    final anchors = <int>{};
    for (final sourceIndex in verifiedSourceIndexes) {
      final targetIndex = sourceIndex + targetOffsetFromSource;
      if (sourceIndex < 0 ||
          sourceIndex >= sourceChapter.pages.length ||
          targetIndex < 0 ||
          targetIndex >= targetChapter.pages.length) {
        continue;
      }
      anchors.add(sourceIndex);
    }
    if (anchors.isEmpty) return 0;
    final sourceStart = targetOffsetFromSource < 0
        ? -targetOffsetFromSource
        : 0;
    final targetStart = targetOffsetFromSource > 0 ? targetOffsetFromSource : 0;
    final sourceRemaining = sourceChapter.pages.length - sourceStart;
    final targetRemaining = targetChapter.pages.length - targetStart;
    final overlap = sourceRemaining < targetRemaining
        ? sourceRemaining
        : targetRemaining;
    if (overlap <= 0) return 0;
    return addVerifiedInterval(
      sourceChapter: sourceChapter,
      sourceStart: sourceStart,
      sourceEndExclusive: sourceStart + overlap,
      targetOffsetFromSource: targetOffsetFromSource,
    );
  }

  Iterable<DownloadId> resolve(DownloadId id) sync* {
    final chapter = targetChapter;
    if (id.content.sourceId != chapter.sourceId ||
        id.content.comicId != chapter.comicId ||
        id.content.chapterId != chapter.chapter.chapterId ||
        id.sourceRevision != chapter.chapter.sourceRevision) {
      return;
    }
    final targetIndex = id.pageIndexHint;
    if (targetIndex == null ||
        targetIndex < 0 ||
        targetIndex >= targetChapter.pages.length) {
      return;
    }
    final hintedPage = targetChapter.pages[targetIndex];
    if (hintedPage.index != targetIndex ||
        hintedPage.pageId != id.content.pageId ||
        hintedPage.uri != id.canonicalUri) {
      return;
    }
    for (final source in _sources) {
      final sourceIndex = targetIndex - source.targetOffsetFromSource;
      if (sourceIndex < source.sourceStart ||
          sourceIndex >= source.sourceEndExclusive) {
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
  /// Bump when the bounded interval-classification contract changes in a way
  /// that requires persisted relation mappings to be probed again once.
  static const int intervalProbeVersion = 1;

  static bool needsIntervalProbe(ComicVersionPageMapping mapping) =>
      mapping.intervalProbeVersion < intervalProbeVersion;

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
      mappings[readerPageDownloadId(newChapter, entry.value)] =
          readerPageDownloadId(oldChapter, oldPage);
    }
    return VerifiedArtifactReusePlan._(mappings);
  }

  /// Produces a bounded set of affine reuse intervals without scanning the
  /// chapter. At most [maxProbeCount] predecessor positions are resolved.
  ///
  /// The common case samples first/middle/last and accepts one whole interval
  /// when all samples agree. A mismatch or offset change recursively splits
  /// only that region. When the fixed budget is exhausted, unresolved spans
  /// remain gaps; already classified probe points remain safe singleton
  /// intervals for later natural browsing/download evidence to expand.
  static Future<VerifiedArtifactIntervalProof?> matchResolvedRelatedIntervals({
    required ChapterManifest sourceChapter,
    required ChapterManifest targetChapter,
    required VerifiedPageReuseIdentityResolver resolveIdentity,
    int maxProbeCount = 8,
  }) async {
    if (sourceChapter.pages.isEmpty ||
        targetChapter.pages.isEmpty ||
        maxProbeCount <= 0) {
      return null;
    }
    final candidateOffsets = <int>{
      0,
      targetChapter.pages.length - sourceChapter.pages.length,
    }.toList(growable: false)..sort();
    final sourceIdentityCache = <int, Future<String?>>{};
    final targetIdentityCache = <int, Future<String?>>{};
    final classifications = <int, int?>{};
    var probeCount = 0;

    Future<String?> identityAt(
      ChapterManifest chapter,
      int index,
      Map<int, Future<String?>> cache,
    ) => cache.putIfAbsent(index, () {
      final page = chapter.pages[index];
      final direct = verifiedPageIdentity(page);
      return direct != null
          ? Future<String?>.value(direct)
          : resolveIdentity(page);
    });

    Future<int?> classify(int sourceIndex) async {
      if (classifications.containsKey(sourceIndex)) {
        return classifications[sourceIndex];
      }
      if (probeCount >= maxProbeCount ||
          sourceIndex < 0 ||
          sourceIndex >= sourceChapter.pages.length) {
        return null;
      }
      probeCount++;
      final sourceIdentity = await identityAt(
        sourceChapter,
        sourceIndex,
        sourceIdentityCache,
      );
      if (sourceIdentity == null) {
        classifications[sourceIndex] = null;
        return null;
      }
      final matches = <int>[];
      for (final offset in candidateOffsets) {
        final targetIndex = sourceIndex + offset;
        if (targetIndex < 0 || targetIndex >= targetChapter.pages.length) {
          continue;
        }
        final targetIdentity = await identityAt(
          targetChapter,
          targetIndex,
          targetIdentityCache,
        );
        if (targetIdentity != null && targetIdentity == sourceIdentity) {
          matches.add(offset);
        }
      }
      final result = matches.length == 1 ? matches.single : null;
      classifications[sourceIndex] = result;
      return result;
    }

    final accepted = <VerifiedComicVersionPageInterval>[];

    Future<void> visit(int start, int endExclusive) async {
      if (start >= endExclusive) return;
      final length = endExclusive - start;
      final points = <int>{
        start,
        start + length ~/ 2,
        endExclusive - 1,
      }.toList(growable: false)..sort();
      for (final point in points) {
        if (!classifications.containsKey(point) && probeCount < maxProbeCount) {
          await classify(point);
        }
      }
      final known = <int?>[
        for (final point in points)
          if (classifications.containsKey(point)) classifications[point],
      ];
      if (known.length == points.length &&
          known.isNotEmpty &&
          known.first != null &&
          known.every((offset) => offset == known.first)) {
        accepted.add(
          VerifiedComicVersionPageInterval(
            predecessorStart: start,
            predecessorEndExclusive: endExclusive,
            successorOffset: known.first!,
          ),
        );
        return;
      }
      if (length == 1) {
        final offset = classifications[start];
        if (offset != null) {
          accepted.add(
            VerifiedComicVersionPageInterval(
              predecessorStart: start,
              predecessorEndExclusive: endExclusive,
              successorOffset: offset,
            ),
          );
        }
        return;
      }
      if (probeCount >= maxProbeCount) {
        for (final point in points) {
          final offset = classifications[point];
          if (offset == null) continue;
          accepted.add(
            VerifiedComicVersionPageInterval(
              predecessorStart: point,
              predecessorEndExclusive: point + 1,
              successorOffset: offset,
            ),
          );
        }
        return;
      }
      final split = start + length ~/ 2;
      await visit(start, split);
      await visit(split, endExclusive);
    }

    await visit(0, sourceChapter.pages.length);
    if (accepted.isEmpty) return null;
    accepted.sort((left, right) {
      final start = left.predecessorStart.compareTo(right.predecessorStart);
      if (start != 0) return start;
      return left.predecessorEndExclusive.compareTo(
        right.predecessorEndExclusive,
      );
    });
    final normalized = <VerifiedComicVersionPageInterval>[];
    for (final interval in accepted) {
      if (normalized.isNotEmpty) {
        final previous = normalized.last;
        if (previous.successorOffset == interval.successorOffset &&
            interval.predecessorStart <= previous.predecessorEndExclusive) {
          normalized[normalized.length - 1] = VerifiedComicVersionPageInterval(
            predecessorStart: previous.predecessorStart,
            predecessorEndExclusive:
                interval.predecessorEndExclusive >
                    previous.predecessorEndExclusive
                ? interval.predecessorEndExclusive
                : previous.predecessorEndExclusive,
            successorOffset: previous.successorOffset,
          );
          continue;
        }
      }
      normalized.add(interval);
    }
    final verifiedIndexes =
        classifications.entries
            .where((entry) => entry.value != null)
            .map((entry) => entry.key)
            .toList(growable: false)
          ..sort();
    final diagnosticIndexes = verifiedIndexes.length <= 3
        ? verifiedIndexes
        : <int>[
            verifiedIndexes.first,
            verifiedIndexes[verifiedIndexes.length ~/ 2],
            verifiedIndexes.last,
          ];
    return VerifiedArtifactIntervalProof(
      verifiedIntervals: normalized,
      verifiedSourceIndexes: diagnosticIndexes,
      probeCount: probeCount,
    );
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
      final indexes = directVerifiedSourceIndexes..sort();
      final anchors = indexes.length <= 3
          ? indexes
          : <int>[indexes.first, indexes[indexes.length ~/ 2], indexes.last];
      return VerifiedArtifactOffsetProof(
        targetOffsetFromSource: directOffsets.single,
        verifiedSourceIndexes: anchors,
      );
    }
    if (sourceChapter.pages.isEmpty || targetChapter.pages.isEmpty) return null;

    final sourcePages = sourceChapter.pages;
    final targetPages = targetChapter.pages;
    final shifts = <int>{sourcePages.length - targetPages.length, 0};
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
          (targetIndex) => resolveIdentity(sourcePages[targetIndex + shift]),
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
    final anchors = verifiedSourceIndexes.toSet();
    if (anchors.isEmpty) {
      return VerifiedArtifactReusePlan._(const <DownloadId, DownloadId>{});
    }
    final mappings = <DownloadId, DownloadId>{};
    for (var sourceIndex = 0; sourceIndex < sourcePages.length; sourceIndex++) {
      final targetIndex = sourceIndex + targetOffsetFromSource;
      if (targetIndex < 0 || targetIndex >= targetPages.length) continue;
      mappings[readerPageDownloadId(targetChapter, targetPages[targetIndex])] =
          readerPageDownloadId(sourceChapter, sourcePages[sourceIndex]);
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
    required this.sourceStart,
    required this.sourceEndExclusive,
    required this.targetOffsetFromSource,
  });

  final ChapterManifest chapter;
  final int sourceStart;
  final int sourceEndExclusive;
  final int targetOffsetFromSource;
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
  final algorithm = page.checksumAlgorithm?.trim().toLowerCase();
  final checksum = algorithm == null || algorithm.isEmpty
      ? null
      : page.sourceChecksumForAlgorithm(algorithm);
  // A digest without its algorithm is not a stable content identity: source
  // adapters have historically used the same field for MD5, SHA and opaque
  // provider tokens. Do not create a cross-version alias from an untyped
  // value ('checksum:$checksum'); strong URI/image identities below remain available.
  // Even when the declared algorithm is crc32 this remains source metadata;
  // it becomes durable artifact proof only after the local sealed bytes are
  // independently hashed by the artifact owner.
  if (checksum != null && algorithm != null && algorithm.isNotEmpty) {
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
  final hash = _uriContentHashPattern
      .firstMatch(page.uri.toString())?.group(0)?.toLowerCase();
  if (hash != null) {
    yield 'hash:$hash';
  }
}

/// Primary verified identity for a page asset.
String? verifiedPageIdentity(PageAsset page) =>
    verifiedPageIdentities(page).firstOrNull;

/// Stable content identity suitable for a persistent physical-media key.
///
/// Only locator-derived identities may directly own physical media.
///
/// Typed checksums remain strong equivalence evidence, but metadata may be
/// enriched after a page first materializes. Letting such enrichment rename a
/// physical owner would recreate the rebind problem canonical media removes.
String? stablePhysicalPageIdentity(PageAsset page) {
  // Physical ownership deliberately ignores checksum metadata because that
  // metadata may be enriched after a page first materializes. Do not route
  // through [verifiedPageIdentities]: doing so normalizes an identity we must
  // discard and also evaluates the URI hash even after an E-Hentai locator is
  // already sufficient.
  final segments = page.uri.pathSegments;
  final marker = segments.indexOf('s');
  if (marker >= 0 && marker + 1 < segments.length) {
    final imageKey = segments[marker + 1].trim().toLowerCase();
    if (imageKey.isNotEmpty) return 'eh:$imageKey';
  }
  final hash = _uriContentHashPattern
      .firstMatch(page.uri.toString())
      ?.group(0)
      ?.toLowerCase();
  return hash == null ? null : 'hash:$hash';
}

PhysicalMediaId? verifiedPhysicalMediaId({
  required String sourceId,
  required PageAsset page,
}) {
  final identity = stablePhysicalPageIdentity(page);
  if (identity == null || sourceId.isEmpty) return null;
  String frame(String value) => '${value.length}:$value';
  return PhysicalMediaId.canonical(
    'verified-page:v1${frame(sourceId)}${frame(identity)}',
  );
}

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
  final hash = RegExp(
    r'[a-fA-F0-9]{32,64}',
  ).firstMatch(uri.toString())?.group(0)?.toLowerCase();
  if (hash != null) {
    yield 'hash:$hash';
  }
}

/// Primary verified identity for a cache record.
String? verifiedRecordIdentity(CacheRec record) =>
    verifiedRecordIdentities(record).firstOrNull;
