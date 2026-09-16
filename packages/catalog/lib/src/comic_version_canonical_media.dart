import 'source_catalog.dart';

/// Stable, opaque identity for one source-confirmed comic version family.
///
/// This is deliberately not a raw/canonical comic locator. It is allocated by
/// the family-membership owner and remains stable as more versions are learned.
final class VersionFamilyId {
  const VersionFamilyId(this.value) : assert(value != '');

  final String value;

  @override
  bool operator ==(Object other) =>
      other is VersionFamilyId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Stable chapter-family identity inside one [VersionFamilyId].
final class CanonicalChapterId {
  const CanonicalChapterId(this.value) : assert(value != '');

  final String value;

  @override
  bool operator ==(Object other) =>
      other is CanonicalChapterId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Stable media-run identity. Segment order is never part of physical identity.
final class CanonicalMediaSegmentId {
  const CanonicalMediaSegmentId(this.value) : assert(value != '');

  final String value;

  @override
  bool operator ==(Object other) =>
      other is CanonicalMediaSegmentId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Version-independent physical media coordinate in the canonical family union.
final class CanonicalMediaCoordinate {
  const CanonicalMediaCoordinate({
    required this.familyId,
    required this.chapterId,
    required this.segmentId,
    required this.offset,
  }) : assert(offset >= 0);

  final VersionFamilyId familyId;
  final CanonicalChapterId chapterId;
  final CanonicalMediaSegmentId segmentId;
  final int offset;

  /// Stable opaque value suitable for a lower-layer physical-media namespace.
  /// Segment order and concrete version identities are deliberately absent.
  String get stableKey =>
      'version-family-media:v1${_canonicalFrame(familyId.value)}'
      '${_canonicalFrame(chapterId.value)}${_canonicalFrame(segmentId.value)}'
      '${_canonicalFrame(offset.toString())}';

  /// Parses only the stable key emitted by [stableKey].
  ///
  /// Management projection uses this to classify already-materialized physical
  /// canonical inventory without expanding every historical version page. A
  /// malformed or unrelated opaque physical key is not a canonical-media fact.
  static CanonicalMediaCoordinate? tryParseStableKey(String value) {
    const prefix = 'version-family-media:v1';
    if (!value.startsWith(prefix)) return null;
    var cursor = prefix.length;
    final frames = <String>[];
    for (var index = 0; index < 4; index++) {
      final frame = _readCanonicalFrame(value, cursor);
      if (frame == null) return null;
      frames.add(frame.value);
      cursor = frame.end;
    }
    if (cursor != value.length) return null;
    final offset = int.tryParse(frames[3]);
    if (frames[0].isEmpty ||
        frames[1].isEmpty ||
        frames[2].isEmpty ||
        offset == null ||
        offset < 0) {
      return null;
    }
    return CanonicalMediaCoordinate(
      familyId: VersionFamilyId(frames[0]),
      chapterId: CanonicalChapterId(frames[1]),
      segmentId: CanonicalMediaSegmentId(frames[2]),
      offset: offset,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CanonicalMediaCoordinate &&
      other.familyId == familyId &&
      other.chapterId == chapterId &&
      other.segmentId == segmentId &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(familyId, chapterId, segmentId, offset);
}

/// One stable run in the canonical media union.
final class CanonicalMediaSegment {
  const CanonicalMediaSegment({required this.id, required this.length})
      : assert(length > 0);

  final CanonicalMediaSegmentId id;
  final int length;
}

/// Compact binding from one exact version's page-index interval into a stable
/// canonical media segment.
///
/// Exact index `i` maps to `segmentStart + (i - exactStart)`. A version can
/// reference discontiguous ranges of one segment when its own page order omits
/// old-only media. New version-only runs receive additional segments without
/// changing the identity of existing segments.
final class CanonicalMediaBindingInterval {
  const CanonicalMediaBindingInterval({
    required this.exactStart,
    required this.exactEndExclusive,
    required this.segmentId,
    required this.segmentStart,
  })  : assert(exactStart >= 0),
        assert(exactEndExclusive > exactStart),
        assert(segmentStart >= 0);

  final int exactStart;
  final int exactEndExclusive;
  final CanonicalMediaSegmentId segmentId;
  final int segmentStart;

  int get length => exactEndExclusive - exactStart;

  bool containsExactIndex(int index) =>
      index >= exactStart && index < exactEndExclusive;

  int segmentOffsetForExactIndex(int index) {
    if (!containsExactIndex(index)) {
      throw RangeError.range(index, exactStart, exactEndExclusive - 1, 'index');
    }
    return segmentStart + index - exactStart;
  }

  Map<String, Object> toJson() => <String, Object>{
        'exactStart': exactStart,
        'exactEndExclusive': exactEndExclusive,
        'segmentId': segmentId.value,
        'segmentStart': segmentStart,
      };

  factory CanonicalMediaBindingInterval.fromJson(Map<String, Object?> json) {
    final exactStart = json['exactStart'];
    final exactEndExclusive = json['exactEndExclusive'];
    final segmentId = json['segmentId'];
    final segmentStart = json['segmentStart'];
    if (exactStart is! int ||
        exactStart < 0 ||
        exactEndExclusive is! int ||
        exactEndExclusive <= exactStart ||
        segmentId is! String ||
        segmentId.isEmpty ||
        segmentStart is! int ||
        segmentStart < 0) {
      throw const FormatException('invalid canonical media binding interval');
    }
    return CanonicalMediaBindingInterval(
      exactStart: exactStart,
      exactEndExclusive: exactEndExclusive,
      segmentId: CanonicalMediaSegmentId(segmentId),
      segmentStart: segmentStart,
    );
  }
}

/// Direct projection of one exact version chapter into the canonical union.
///
/// This projection contains no predecessor/successor walk. Pairwise
/// [ComicVersionPageMapping] evidence is consumed only while building a newer
/// direct projection.
final class VersionChapterCanonicalProjection {
  VersionChapterCanonicalProjection({
    required this.familyId,
    required this.canonicalChapterId,
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.sourceRevision,
    required this.pageCount,
    required Iterable<CanonicalMediaBindingInterval> intervals,
  }) : intervals = List<CanonicalMediaBindingInterval>.unmodifiable(intervals) {
    if (sourceId.isEmpty ||
        comicId.isEmpty ||
        chapterId.isEmpty ||
        sourceRevision.isEmpty ||
        pageCount <= 0) {
      throw ArgumentError('version chapter identity and pageCount must be valid');
    }
    var cursor = 0;
    for (final interval in this.intervals) {
      if (interval.exactStart < cursor || interval.exactEndExclusive > pageCount) {
        throw ArgumentError(
          'canonical projection intervals must be ordered and non-overlapping',
        );
      }
      cursor = interval.exactEndExclusive;
    }
  }

  final VersionFamilyId familyId;
  final CanonicalChapterId canonicalChapterId;
  final String sourceId;
  final String comicId;
  final String chapterId;
  final String sourceRevision;
  final int pageCount;
  final List<CanonicalMediaBindingInterval> intervals;

  String get exactKey =>
      _exactKey(sourceId, comicId, chapterId, sourceRevision);

  int get boundPageCount => intervals.fold<int>(
        0,
        (total, interval) => total + interval.length,
      );

  CanonicalMediaCoordinate? coordinateForPageIndexOrNull(int index) {
    if (index < 0 || index >= pageCount) return null;
    for (final interval in intervals) {
      if (interval.exactStart > index) break;
      if (!interval.containsExactIndex(index)) continue;
      return CanonicalMediaCoordinate(
        familyId: familyId,
        chapterId: canonicalChapterId,
        segmentId: interval.segmentId,
        offset: interval.segmentOffsetForExactIndex(index),
      );
    }
    return null;
  }

  CanonicalMediaCoordinate coordinateForPageIndex(int index) {
    if (index < 0 || index >= pageCount) {
      throw RangeError.range(index, 0, pageCount - 1, 'index');
    }
    final coordinate = coordinateForPageIndexOrNull(index);
    if (coordinate != null) return coordinate;
    throw StateError('canonical projection has no binding for page index $index');
  }

  VersionChapterCanonicalProjection copyWithIntervals(
    Iterable<CanonicalMediaBindingInterval> values,
  ) =>
      VersionChapterCanonicalProjection(
        familyId: familyId,
        canonicalChapterId: canonicalChapterId,
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
        sourceRevision: sourceRevision,
        pageCount: pageCount,
        intervals: values,
      );

  Map<String, Object> toJson() => <String, Object>{
        'familyId': familyId.value,
        'canonicalChapterId': canonicalChapterId.value,
        'sourceId': sourceId,
        'comicId': comicId,
        'chapterId': chapterId,
        'sourceRevision': sourceRevision,
        'pageCount': pageCount,
        'intervals': intervals.map((interval) => interval.toJson()).toList(),
      };

  factory VersionChapterCanonicalProjection.fromJson(
    Map<String, Object?> json,
  ) {
    final familyId = json['familyId'];
    final canonicalChapterId = json['canonicalChapterId'];
    final sourceId = json['sourceId'];
    final comicId = json['comicId'];
    final chapterId = json['chapterId'];
    final sourceRevision = json['sourceRevision'];
    final pageCount = json['pageCount'];
    final rawIntervals = json['intervals'];
    if (familyId is! String ||
        familyId.isEmpty ||
        canonicalChapterId is! String ||
        canonicalChapterId.isEmpty ||
        sourceId is! String ||
        sourceId.isEmpty ||
        comicId is! String ||
        comicId.isEmpty ||
        chapterId is! String ||
        chapterId.isEmpty ||
        sourceRevision is! String ||
        sourceRevision.isEmpty ||
        pageCount is! int ||
        pageCount <= 0 ||
        rawIntervals is! List) {
      throw const FormatException('invalid canonical chapter projection');
    }
    final intervals = <CanonicalMediaBindingInterval>[];
    for (final value in rawIntervals) {
      if (value is! Map) {
        throw const FormatException('invalid canonical chapter projection');
      }
      intervals.add(
        CanonicalMediaBindingInterval.fromJson(
          Map<String, Object?>.from(value),
        ),
      );
    }
    return VersionChapterCanonicalProjection(
      familyId: VersionFamilyId(familyId),
      canonicalChapterId: CanonicalChapterId(canonicalChapterId),
      sourceId: sourceId,
      comicId: comicId,
      chapterId: chapterId,
      sourceRevision: sourceRevision,
      pageCount: pageCount,
      intervals: intervals,
    );
  }
}


/// Control-plane builder for a stable canonical media union.
///
/// It intentionally mutates only by appending segments and adding direct
/// version projections. Existing projections and segment identities are never
/// rebased when a newer version is integrated.
final class ComicVersionCanonicalMediaUnion {
  ComicVersionCanonicalMediaUnion({required this.familyId});

  final VersionFamilyId familyId;
  final Map<CanonicalChapterId, List<CanonicalMediaSegment>> _segments =
      <CanonicalChapterId, List<CanonicalMediaSegment>>{};
  final Map<String, VersionChapterCanonicalProjection> _projections =
      <String, VersionChapterCanonicalProjection>{};
  int _nextChapterOrdinal = 0;
  int _nextSegmentOrdinal = 0;

  int get chapterCount => _segments.length;
  int get segmentCount =>
      _segments.values.fold<int>(0, (total, values) => total + values.length);

  Iterable<VersionChapterCanonicalProjection> get projections =>
      _projections.values;

  List<CanonicalMediaSegment> segmentsFor(CanonicalChapterId chapterId) =>
      List<CanonicalMediaSegment>.unmodifiable(
        _segments[chapterId] ?? const <CanonicalMediaSegment>[],
      );

  VersionChapterCanonicalProjection? projectionFor({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String sourceRevision,
  }) =>
      _projections[_exactKey(sourceId, comicId, chapterId, sourceRevision)];

  /// Seeds the union from the first materialized/adopted chapter in a family.
  /// One continuous chapter needs one segment regardless of page count.
  VersionChapterCanonicalProjection seedChapter({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String sourceRevision,
    required int pageCount,
  }) {
    if (pageCount <= 0) {
      throw ArgumentError.value(pageCount, 'pageCount', 'must be positive');
    }
    final key = _exactKey(sourceId, comicId, chapterId, sourceRevision);
    if (_projections.containsKey(key)) {
      throw StateError('exact version chapter already belongs to the union');
    }
    final canonicalChapterId = _newChapterId();
    final segment = _appendSegment(canonicalChapterId, pageCount);
    final projection = VersionChapterCanonicalProjection(
      familyId: familyId,
      canonicalChapterId: canonicalChapterId,
      sourceId: sourceId,
      comicId: comicId,
      chapterId: chapterId,
      sourceRevision: sourceRevision,
      pageCount: pageCount,
      intervals: <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: pageCount,
          segmentId: segment.id,
          segmentStart: 0,
        ),
      ],
    );
    _projections[key] = projection;
    return projection;
  }

  /// Integrates one verified successor chapter into an existing canonical
  /// chapter without modifying the predecessor projection or any existing
  /// segment identity.
  ///
  /// Verified predecessor ranges inherit the predecessor's canonical media.
  /// Successor ranges not covered by verified equivalence become new stable
  /// segments. This naturally represents inserted/replaced/new-only media.
  VersionChapterCanonicalProjection integrateSuccessor({
    required VersionChapterCanonicalProjection predecessor,
    required String successorComicId,
    required String successorChapterId,
    required String successorSourceRevision,
    required int successorPageCount,
    required ComicVersionPageMapping mapping,
  }) {
    _requireOwnedProjection(predecessor);
    if (successorComicId.isEmpty ||
        successorChapterId.isEmpty ||
        successorSourceRevision.isEmpty ||
        successorPageCount <= 0) {
      throw ArgumentError('successor identity and pageCount must be valid');
    }
    if (mapping.predecessorChapterId != predecessor.chapterId ||
        mapping.successorChapterId != successorChapterId ||
        mapping.predecessorPageCount != predecessor.pageCount ||
        mapping.successorPageCount != successorPageCount ||
        (mapping.predecessorSourceRevision != null &&
            mapping.predecessorSourceRevision != predecessor.sourceRevision) ||
        (mapping.successorSourceRevision != null &&
            mapping.successorSourceRevision != successorSourceRevision)) {
      throw ArgumentError('mapping does not describe the supplied version pair');
    }
    final key = _exactKey(
      predecessor.sourceId,
      successorComicId,
      successorChapterId,
      successorSourceRevision,
    );
    if (_projections.containsKey(key)) {
      throw StateError('successor version chapter already belongs to the union');
    }

    final inherited = <CanonicalMediaBindingInterval>[];
    for (final verified in mapping.effectiveVerifiedIntervals) {
      for (final sourceBinding in predecessor.intervals) {
        final start = _max(verified.predecessorStart, sourceBinding.exactStart);
        final end = _min(
          verified.predecessorEndExclusive,
          sourceBinding.exactEndExclusive,
        );
        if (start >= end) continue;
        final successorStart = start + verified.successorOffset;
        final successorEnd = end + verified.successorOffset;
        if (successorStart < 0 || successorEnd > successorPageCount) {
          throw StateError('verified interval maps outside successor page range');
        }
        inherited.add(
          CanonicalMediaBindingInterval(
            exactStart: successorStart,
            exactEndExclusive: successorEnd,
            segmentId: sourceBinding.segmentId,
            segmentStart:
                sourceBinding.segmentStart + start - sourceBinding.exactStart,
          ),
        );
      }
    }
    inherited.sort((left, right) {
      final start = left.exactStart.compareTo(right.exactStart);
      if (start != 0) return start;
      return left.exactEndExclusive.compareTo(right.exactEndExclusive);
    });

    final normalizedInherited = _normalizeInherited(inherited);
    // Gaps are unknown, not evidence of version-private media. Keep them
    // exact-only until a later verified relation gives them a canonical peer
    // (or a strong page identity supplies an independent physical key).
    final complete = normalizedInherited;

    final projection = VersionChapterCanonicalProjection(
      familyId: familyId,
      canonicalChapterId: predecessor.canonicalChapterId,
      sourceId: predecessor.sourceId,
      comicId: successorComicId,
      chapterId: successorChapterId,
      sourceRevision: successorSourceRevision,
      pageCount: successorPageCount,
      intervals: _mergeAdjacentBindings(complete),
    );
    _projections[key] = projection;
    return projection;
  }

  void _requireOwnedProjection(VersionChapterCanonicalProjection projection) {
    if (projection.familyId != familyId ||
        !identical(_projections[projection.exactKey], projection)) {
      throw ArgumentError('predecessor projection is not owned by this union');
    }
  }

  CanonicalChapterId _newChapterId() =>
      CanonicalChapterId('chapter-${++_nextChapterOrdinal}');

  CanonicalMediaSegment _appendSegment(
    CanonicalChapterId chapterId,
    int length,
  ) {
    final segment = CanonicalMediaSegment(
      id: CanonicalMediaSegmentId('segment-${++_nextSegmentOrdinal}'),
      length: length,
    );
    _segments.putIfAbsent(chapterId, () => <CanonicalMediaSegment>[]).add(segment);
    return segment;
  }

  List<CanonicalMediaBindingInterval> _normalizeInherited(
    List<CanonicalMediaBindingInterval> values,
  ) {
    if (values.isEmpty) return const <CanonicalMediaBindingInterval>[];
    final result = <CanonicalMediaBindingInterval>[];
    for (final current in values) {
      if (result.isEmpty) {
        result.add(current);
        continue;
      }
      final previous = result.last;
      if (current.exactStart < previous.exactEndExclusive) {
        final previousCoordinate = previous.segmentStart +
            current.exactStart - previous.exactStart;
        if (current.segmentId != previous.segmentId ||
            current.segmentStart != previousCoordinate) {
          throw StateError(
            'overlapping verified ranges disagree on canonical media',
          );
        }
        if (current.exactEndExclusive > previous.exactEndExclusive) {
          result[result.length - 1] = CanonicalMediaBindingInterval(
            exactStart: previous.exactStart,
            exactEndExclusive: current.exactEndExclusive,
            segmentId: previous.segmentId,
            segmentStart: previous.segmentStart,
          );
        }
        continue;
      }
      if (_canMerge(previous, current)) {
        result[result.length - 1] = CanonicalMediaBindingInterval(
          exactStart: previous.exactStart,
          exactEndExclusive: current.exactEndExclusive,
          segmentId: previous.segmentId,
          segmentStart: previous.segmentStart,
        );
      } else {
        result.add(current);
      }
    }
    return result;
  }

  List<CanonicalMediaBindingInterval> _mergeAdjacentBindings(
    Iterable<CanonicalMediaBindingInterval> values,
  ) {
    final result = <CanonicalMediaBindingInterval>[];
    for (final current in values) {
      if (result.isNotEmpty && _canMerge(result.last, current)) {
        final previous = result.last;
        result[result.length - 1] = CanonicalMediaBindingInterval(
          exactStart: previous.exactStart,
          exactEndExclusive: current.exactEndExclusive,
          segmentId: previous.segmentId,
          segmentStart: previous.segmentStart,
        );
      } else {
        result.add(current);
      }
    }
    return result;
  }

  bool _canMerge(
    CanonicalMediaBindingInterval left,
    CanonicalMediaBindingInterval right,
  ) =>
      left.exactEndExclusive == right.exactStart &&
      left.segmentId == right.segmentId &&
      left.segmentStart + left.length == right.segmentStart;
}


final class CanonicalMediaConflict {
  const CanonicalMediaConflict({
    required this.predecessorStart,
    required this.predecessorEndExclusive,
    required this.successorStart,
    required this.reason,
  });

  final int predecessorStart;
  final int predecessorEndExclusive;
  final int successorStart;
  final String reason;
}

final class CanonicalMediaMergeResult {
  const CanonicalMediaMergeResult({
    required this.predecessor,
    required this.successor,
    required this.predecessorChanged,
    required this.successorChanged,
    required this.conflicts,
  });

  final VersionChapterCanonicalProjection predecessor;
  final VersionChapterCanonicalProjection successor;
  final bool predecessorChanged;
  final bool successorChanged;
  final List<CanonicalMediaConflict> conflicts;

  bool get hasConflict => conflicts.isNotEmpty;
  bool get changed => predecessorChanged || successorChanged;
}

/// Monotonic compact canonical-media ledger.
///
/// Existing bindings are immutable. A newly verified range may fill an
/// unbound span or make an unbound peer inherit an existing coordinate. If
/// both peers already own different coordinates, the ledger records a conflict
/// and leaves both unchanged; there is no automatic family merge or rebase.
/// Unknown spans outside current verified intervals stay unbound/exact-only.
final class ComicVersionCanonicalMediaLedger {
  ComicVersionCanonicalMediaLedger({
    Iterable<VersionChapterCanonicalProjection> projections =
        const <VersionChapterCanonicalProjection>[],
  }) {
    for (final projection in projections) {
      final previous = _projections[projection.exactKey];
      if (previous != null && !_sameProjection(previous, projection)) {
        throw StateError(
          'conflicting canonical projection for ${projection.exactKey}',
        );
      }
      _projections[projection.exactKey] = projection;
    }
  }

  final Map<String, VersionChapterCanonicalProjection> _projections =
      <String, VersionChapterCanonicalProjection>{};

  Iterable<VersionChapterCanonicalProjection> get projections =>
      _projections.values;

  VersionChapterCanonicalProjection? projectionForExactKey(String exactKey) =>
      _projections[exactKey];

  CanonicalMediaMergeResult mergeVerifiedMapping({
    required String sourceId,
    required String predecessorComicId,
    required String successorComicId,
    required String predecessorChapterId,
    required String successorChapterId,
    required String predecessorSourceRevision,
    required String successorSourceRevision,
    required int predecessorPageCount,
    required int successorPageCount,
    required Iterable<VerifiedComicVersionPageInterval> verifiedIntervals,
  }) {
    final predecessorKey = _exactKey(
      sourceId,
      predecessorComicId,
      predecessorChapterId,
      predecessorSourceRevision,
    );
    final successorKey = _exactKey(
      sourceId,
      successorComicId,
      successorChapterId,
      successorSourceRevision,
    );
    var predecessor = _projections[predecessorKey];
    var successor = _projections[successorKey];
    final originalPredecessor = predecessor;
    final originalSuccessor = successor;

    final predecessorFamily = predecessor?.familyId ??
        _familyForComic(sourceId, predecessorComicId);
    final successorFamily = successor?.familyId ??
        _familyForComic(sourceId, successorComicId);
    if (predecessorFamily != null &&
        successorFamily != null &&
        predecessorFamily != successorFamily) {
      final fallbackPredecessor = predecessor ?? _emptyProjection(
        familyId: predecessorFamily,
        canonicalChapterId: _originChapterId(predecessorKey),
        sourceId: sourceId,
        comicId: predecessorComicId,
        chapterId: predecessorChapterId,
        sourceRevision: predecessorSourceRevision,
        pageCount: predecessorPageCount,
      );
      final fallbackSuccessor = successor ?? _emptyProjection(
        familyId: successorFamily,
        canonicalChapterId: _originChapterId(successorKey),
        sourceId: sourceId,
        comicId: successorComicId,
        chapterId: successorChapterId,
        sourceRevision: successorSourceRevision,
        pageCount: successorPageCount,
      );
      return CanonicalMediaMergeResult(
        predecessor: fallbackPredecessor,
        successor: fallbackSuccessor,
        predecessorChanged: false,
        successorChanged: false,
        conflicts: <CanonicalMediaConflict>[
          for (final interval in verifiedIntervals)
            CanonicalMediaConflict(
              predecessorStart: interval.predecessorStart,
              predecessorEndExclusive: interval.predecessorEndExclusive,
              successorStart:
                  interval.predecessorStart + interval.successorOffset,
              reason: 'verified relation connects two established families',
            ),
        ],
      );
    }

    final familyId = predecessorFamily ??
        successorFamily ??
        _familyIdForRelation(
          sourceId,
          predecessorComicId,
          successorComicId,
        );
    final canonicalChapterId = predecessor?.canonicalChapterId ??
        successor?.canonicalChapterId ??
        _originChapterId(predecessorKey);
    predecessor ??= _emptyProjection(
      familyId: familyId,
      canonicalChapterId: canonicalChapterId,
      sourceId: sourceId,
      comicId: predecessorComicId,
      chapterId: predecessorChapterId,
      sourceRevision: predecessorSourceRevision,
      pageCount: predecessorPageCount,
    );
    successor ??= _emptyProjection(
      familyId: familyId,
      canonicalChapterId: canonicalChapterId,
      sourceId: sourceId,
      comicId: successorComicId,
      chapterId: successorChapterId,
      sourceRevision: successorSourceRevision,
      pageCount: successorPageCount,
    );
    if (predecessor.familyId != familyId ||
        successor.familyId != familyId ||
        predecessor.canonicalChapterId != successor.canonicalChapterId) {
      return CanonicalMediaMergeResult(
        predecessor: predecessor,
        successor: successor,
        predecessorChanged: false,
        successorChanged: false,
        conflicts: <CanonicalMediaConflict>[
          for (final interval in verifiedIntervals)
            CanonicalMediaConflict(
              predecessorStart: interval.predecessorStart,
              predecessorEndExclusive: interval.predecessorEndExclusive,
              successorStart:
                  interval.predecessorStart + interval.successorOffset,
              reason: 'verified relation connects different canonical chapters',
            ),
        ],
      );
    }
    if (predecessor.pageCount != predecessorPageCount ||
        successor.pageCount != successorPageCount) {
      throw StateError('canonical projection page count changed for one exact revision');
    }

    var predecessorBindings = predecessor.intervals.toList(growable: true);
    var successorBindings = successor.intervals.toList(growable: true);
    final conflicts = <CanonicalMediaConflict>[];
    for (final verified in verifiedIntervals) {
      if (verified.predecessorStart < 0 ||
          verified.predecessorEndExclusive > predecessorPageCount) {
        continue;
      }
      final successorStart =
          verified.predecessorStart + verified.successorOffset;
      final successorEnd =
          verified.predecessorEndExclusive + verified.successorOffset;
      if (successorStart < 0 || successorEnd > successorPageCount) continue;

      final boundaries = <int>{
        verified.predecessorStart,
        verified.predecessorEndExclusive,
      };
      for (final binding in predecessorBindings) {
        if (binding.exactEndExclusive <= verified.predecessorStart ||
            binding.exactStart >= verified.predecessorEndExclusive) {
          continue;
        }
        boundaries.add(_max(binding.exactStart, verified.predecessorStart));
        boundaries.add(
          _min(binding.exactEndExclusive, verified.predecessorEndExclusive),
        );
      }
      for (final binding in successorBindings) {
        final translatedStart = binding.exactStart - verified.successorOffset;
        final translatedEnd =
            binding.exactEndExclusive - verified.successorOffset;
        if (translatedEnd <= verified.predecessorStart ||
            translatedStart >= verified.predecessorEndExclusive) {
          continue;
        }
        boundaries.add(_max(translatedStart, verified.predecessorStart));
        boundaries.add(_min(translatedEnd, verified.predecessorEndExclusive));
      }
      final ordered = boundaries.toList()..sort();
      for (var index = 0; index + 1 < ordered.length; index++) {
        final start = ordered[index];
        final end = ordered[index + 1];
        if (start >= end) continue;
        final peerStart = start + verified.successorOffset;
        final predecessorBinding = _bindingAt(predecessorBindings, start);
        final successorBinding = _bindingAt(successorBindings, peerStart);
        if (predecessorBinding == null && successorBinding == null) {
          final originSegment = _originSegmentId(predecessorKey);
          predecessorBindings = _insertBinding(
            predecessorBindings,
            CanonicalMediaBindingInterval(
              exactStart: start,
              exactEndExclusive: end,
              segmentId: originSegment,
              segmentStart: start,
            ),
          );
          successorBindings = _insertBinding(
            successorBindings,
            CanonicalMediaBindingInterval(
              exactStart: peerStart,
              exactEndExclusive: end + verified.successorOffset,
              segmentId: originSegment,
              segmentStart: start,
            ),
          );
          continue;
        }
        if (predecessorBinding != null && successorBinding == null) {
          successorBindings = _insertBinding(
            successorBindings,
            CanonicalMediaBindingInterval(
              exactStart: peerStart,
              exactEndExclusive: end + verified.successorOffset,
              segmentId: predecessorBinding.segmentId,
              segmentStart: predecessorBinding.segmentOffsetForExactIndex(start),
            ),
          );
          continue;
        }
        if (predecessorBinding == null && successorBinding != null) {
          predecessorBindings = _insertBinding(
            predecessorBindings,
            CanonicalMediaBindingInterval(
              exactStart: start,
              exactEndExclusive: end,
              segmentId: successorBinding.segmentId,
              segmentStart:
                  successorBinding.segmentOffsetForExactIndex(peerStart),
            ),
          );
          continue;
        }
        final predecessorCoordinate =
            predecessorBinding!.segmentOffsetForExactIndex(start);
        final successorCoordinate =
            successorBinding!.segmentOffsetForExactIndex(peerStart);
        if (predecessorBinding.segmentId == successorBinding.segmentId &&
            predecessorCoordinate == successorCoordinate) {
          continue;
        }
        conflicts.add(
          CanonicalMediaConflict(
            predecessorStart: start,
            predecessorEndExclusive: end,
            successorStart: peerStart,
            reason: 'both verified peers already own different canonical media',
          ),
        );
      }
    }

    predecessor = predecessor.copyWithIntervals(
      _mergeBindingIntervals(predecessorBindings),
    );
    successor = successor.copyWithIntervals(
      _mergeBindingIntervals(successorBindings),
    );
    _projections[predecessor.exactKey] = predecessor;
    _projections[successor.exactKey] = successor;
    return CanonicalMediaMergeResult(
      predecessor: predecessor,
      successor: successor,
      predecessorChanged: originalPredecessor == null ||
          !_sameProjection(originalPredecessor, predecessor),
      successorChanged: originalSuccessor == null ||
          !_sameProjection(originalSuccessor, successor),
      conflicts: List<CanonicalMediaConflict>.unmodifiable(conflicts),
    );
  }

  VersionFamilyId? _familyForComic(String sourceId, String comicId) {
    VersionFamilyId? found;
    for (final projection in _projections.values) {
      if (projection.sourceId != sourceId || projection.comicId != comicId) {
        continue;
      }
      if (found != null && found != projection.familyId) {
        throw StateError('one exact comic is present in multiple canonical families');
      }
      found = projection.familyId;
    }
    return found;
  }
}

VersionChapterCanonicalProjection _emptyProjection({
  required VersionFamilyId familyId,
  required CanonicalChapterId canonicalChapterId,
  required String sourceId,
  required String comicId,
  required String chapterId,
  required String sourceRevision,
  required int pageCount,
}) =>
    VersionChapterCanonicalProjection(
      familyId: familyId,
      canonicalChapterId: canonicalChapterId,
      sourceId: sourceId,
      comicId: comicId,
      chapterId: chapterId,
      sourceRevision: sourceRevision,
      pageCount: pageCount,
      intervals: const <CanonicalMediaBindingInterval>[],
    );

CanonicalMediaBindingInterval? _bindingAt(
  List<CanonicalMediaBindingInterval> values,
  int index,
) {
  for (final value in values) {
    if (value.exactStart > index) return null;
    if (value.containsExactIndex(index)) return value;
  }
  return null;
}

List<CanonicalMediaBindingInterval> _insertBinding(
  List<CanonicalMediaBindingInterval> values,
  CanonicalMediaBindingInterval addition,
) {
  final next = <CanonicalMediaBindingInterval>[...values, addition]
    ..sort((left, right) => left.exactStart.compareTo(right.exactStart));
  var cursor = 0;
  for (final value in next) {
    if (value.exactStart < cursor) {
      throw StateError('canonical media binding overlaps existing projection');
    }
    cursor = value.exactEndExclusive;
  }
  return next;
}

List<CanonicalMediaBindingInterval> _mergeBindingIntervals(
  Iterable<CanonicalMediaBindingInterval> values,
) {
  final ordered = values.toList()
    ..sort((left, right) => left.exactStart.compareTo(right.exactStart));
  final result = <CanonicalMediaBindingInterval>[];
  for (final current in ordered) {
    if (result.isEmpty) {
      result.add(current);
      continue;
    }
    final previous = result.last;
    final contiguous = previous.exactEndExclusive == current.exactStart &&
        previous.segmentId == current.segmentId &&
        previous.segmentStart + previous.length == current.segmentStart;
    if (!contiguous) {
      result.add(current);
      continue;
    }
    result[result.length - 1] = CanonicalMediaBindingInterval(
      exactStart: previous.exactStart,
      exactEndExclusive: current.exactEndExclusive,
      segmentId: previous.segmentId,
      segmentStart: previous.segmentStart,
    );
  }
  return result;
}

bool _sameProjection(
  VersionChapterCanonicalProjection left,
  VersionChapterCanonicalProjection right,
) =>
    left.familyId == right.familyId &&
    left.canonicalChapterId == right.canonicalChapterId &&
    left.sourceId == right.sourceId &&
    left.comicId == right.comicId &&
    left.chapterId == right.chapterId &&
    left.sourceRevision == right.sourceRevision &&
    left.pageCount == right.pageCount &&
    _sameBindings(left.intervals, right.intervals);

bool _sameBindings(
  List<CanonicalMediaBindingInterval> left,
  List<CanonicalMediaBindingInterval> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a.exactStart != b.exactStart ||
        a.exactEndExclusive != b.exactEndExclusive ||
        a.segmentId != b.segmentId ||
        a.segmentStart != b.segmentStart) {
      return false;
    }
  }
  return true;
}

VersionFamilyId _familyIdForRelation(
  String sourceId,
  String predecessorComicId,
  String successorComicId,
) =>
    VersionFamilyId(
      'family-origin:v1${_canonicalFrame(sourceId)}'
      '${_canonicalFrame(predecessorComicId)}'
      '${_canonicalFrame(successorComicId)}',
    );

CanonicalChapterId _originChapterId(String exactKey) =>
    CanonicalChapterId('chapter-origin:v1${_canonicalFrame(exactKey)}');

CanonicalMediaSegmentId _originSegmentId(String exactKey) =>
    CanonicalMediaSegmentId('segment-origin:v1${_canonicalFrame(exactKey)}');

String _exactKey(
  String sourceId,
  String comicId,
  String chapterId,
  String sourceRevision,
) =>
    '$sourceId\u0000$comicId\u0000$chapterId\u0000$sourceRevision';

int _min(int left, int right) => left < right ? left : right;
int _max(int left, int right) => left > right ? left : right;

String _canonicalFrame(String value) => '${value.length}:$value';

({String value, int end})? _readCanonicalFrame(String source, int start) {
  if (start < 0 || start >= source.length) return null;
  final separator = source.indexOf(':', start);
  if (separator < 0) return null;
  final rawLength = source.substring(start, separator);
  if (rawLength.isEmpty || rawLength.length > 10) return null;
  final length = int.tryParse(rawLength);
  if (length == null || length < 0) return null;
  final valueStart = separator + 1;
  final end = valueStart + length;
  if (end > source.length) return null;
  return (value: source.substring(valueStart, end), end: end);
}
