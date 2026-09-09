import 'source_catalog.dart';

/// Exact source/version identity used when resolving runtime version baselines.
final class ComicVersionIdentity {
  const ComicVersionIdentity({
    required this.sourceId,
    required this.comicId,
  });

  final String sourceId;
  final String comicId;

  String get key => '$sourceId\u0000$comicId';
}

/// One historical version family projected onto the runtime heads that matter.
///
/// Historical predecessor/successor edges remain provenance. Consumers should
/// use these heads instead of walking that history on every read or rebuild.
final class ComicVersionFamilyBaseline {
  ComicVersionFamilyBaseline({
    required this.sourceId,
    required Iterable<String> memberComicIds,
    this.latestKnownComicId,
    this.latestKnownDiscoveredAt,
    this.shelfHeadComicId,
    this.downloadHeadComicId,
    Iterable<String> shelfBaselineComicIds = const <String>[],
    Iterable<String> downloadBaselineComicIds = const <String>[],
  })  : memberComicIds = Set<String>.unmodifiable(memberComicIds),
        shelfBaselineComicIds =
            Set<String>.unmodifiable(shelfBaselineComicIds),
        downloadBaselineComicIds =
            Set<String>.unmodifiable(downloadBaselineComicIds);

  final String sourceId;
  final Set<String> memberComicIds;
  final String? latestKnownComicId;
  final DateTime? latestKnownDiscoveredAt;
  final String? shelfHeadComicId;
  final String? downloadHeadComicId;
  final Set<String> shelfBaselineComicIds;
  final Set<String> downloadBaselineComicIds;

  bool contains(String sourceId, String comicId) =>
      this.sourceId == sourceId && memberComicIds.contains(comicId);
}

/// Runtime projection of durable version history.
///
/// [downloadHeadRelations] contains only direct predecessor -> current
/// download-head relations. Their page mappings are composed from a unique
/// verified historical path. No consumer needs to traverse historical edges.
final class ComicVersionBaselineProjection {
  ComicVersionBaselineProjection({
    required Iterable<ComicVersionFamilyBaseline> families,
    required Iterable<ComicVersionRelation> downloadHeadRelations,
  })  : families = List<ComicVersionFamilyBaseline>.unmodifiable(families),
        downloadHeadRelations =
            List<ComicVersionRelation>.unmodifiable(downloadHeadRelations);

  const ComicVersionBaselineProjection._empty()
      : families = const <ComicVersionFamilyBaseline>[],
        downloadHeadRelations = const <ComicVersionRelation>[];

  static const empty = ComicVersionBaselineProjection._empty();

  final List<ComicVersionFamilyBaseline> families;
  final List<ComicVersionRelation> downloadHeadRelations;

  ComicVersionFamilyBaseline? familyFor(String sourceId, String comicId) {
    for (final family in families) {
      if (family.contains(sourceId, comicId)) return family;
    }
    return null;
  }

  String? latestKnownHeadFor(String sourceId, String comicId) =>
      familyFor(sourceId, comicId)?.latestKnownComicId;

  String? shelfHeadFor(String sourceId, String comicId) {
    final family = familyFor(sourceId, comicId);
    return family != null && family.shelfBaselineComicIds.contains(comicId)
        ? family.shelfHeadComicId
        : null;
  }

  String? downloadHeadFor(String sourceId, String comicId) {
    final family = familyFor(sourceId, comicId);
    return family != null && family.downloadBaselineComicIds.contains(comicId)
        ? family.downloadHeadComicId
        : null;
  }
}

/// Resolves compact historical version relations into current runtime heads.
///
/// A head is selected only when one candidate is a directed successor of every
/// other materialized candidate in that family. Ambiguous branches therefore
/// remain exact instead of being guessed into one baseline.
ComicVersionBaselineProjection resolveComicVersionBaselines({
  required Iterable<ComicVersionRelation> relations,
  Iterable<ComicVersionIdentity> shelfComics = const <ComicVersionIdentity>[],
  Iterable<ComicVersionIdentity> manualDownloadComics =
      const <ComicVersionIdentity>[],
}) {
  final history = List<ComicVersionRelation>.unmodifiable(relations);
  final nodesBySource = <String, Set<String>>{};
  final outgoing = <String, List<ComicVersionRelation>>{};
  final undirected = <String, Set<String>>{};

  String node(String sourceId, String comicId) => '$sourceId\u0000$comicId';

  void addNode(String sourceId, String comicId) {
    nodesBySource.putIfAbsent(sourceId, () => <String>{}).add(comicId);
    undirected.putIfAbsent(node(sourceId, comicId), () => <String>{});
  }

  for (final relation in history) {
    addNode(relation.sourceId, relation.predecessorComicId);
    addNode(relation.sourceId, relation.successorComicId);
    final predecessor = node(relation.sourceId, relation.predecessorComicId);
    final successor = node(relation.sourceId, relation.successorComicId);
    outgoing.putIfAbsent(predecessor, () => <ComicVersionRelation>[]).add(relation);
    undirected[predecessor]!.add(successor);
    undirected[successor]!.add(predecessor);
  }
  for (final identity in <ComicVersionIdentity>[...shelfComics, ...manualDownloadComics]) {
    addNode(identity.sourceId, identity.comicId);
  }

  final shelfKeys = <String>{for (final item in shelfComics) item.key};
  final downloadKeys = <String>{for (final item in manualDownloadComics) item.key};
  final families = <ComicVersionFamilyBaseline>[];
  final directDownloadRelations = <ComicVersionRelation>[];
  final visited = <String>{};

  bool reaches(String sourceId, String fromComicId, String toComicId) {
    if (fromComicId == toComicId) return true;
    final seen = <String>{fromComicId};
    final pending = <String>[fromComicId];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      for (final relation in outgoing[node(sourceId, current)] ??
          const <ComicVersionRelation>[]) {
        final successor = relation.successorComicId;
        if (successor == toComicId) return true;
        if (seen.add(successor)) pending.add(successor);
      }
    }
    return false;
  }

  String? dominantHead(String sourceId, Iterable<String> candidates) {
    final values = candidates.toSet();
    if (values.isEmpty) return null;
    if (values.length == 1) return values.single;
    final dominant = <String>[
      for (final candidate in values)
        if (values.every((other) => reaches(sourceId, other, candidate)))
          candidate,
    ];
    return dominant.length == 1 ? dominant.single : null;
  }

  List<ComicVersionRelation>? uniquePath(
    String sourceId,
    String fromComicId,
    String toComicId,
  ) {
    if (fromComicId == toComicId) return const <ComicVersionRelation>[];
    final results = <List<ComicVersionRelation>>[];
    void visit(
      String current,
      Set<String> pathNodes,
      List<ComicVersionRelation> path,
    ) {
      if (results.length > 1) return;
      for (final relation in outgoing[node(sourceId, current)] ??
          const <ComicVersionRelation>[]) {
        final next = relation.successorComicId;
        if (!pathNodes.add(next)) continue;
        final nextPath = <ComicVersionRelation>[...path, relation];
        if (next == toComicId) {
          results.add(nextPath);
        } else {
          visit(next, pathNodes, nextPath);
        }
        pathNodes.remove(next);
      }
    }

    visit(fromComicId, <String>{fromComicId}, const <ComicVersionRelation>[]);
    return results.length == 1 ? results.single : null;
  }

  DateTime? earlierVerifiedAt(DateTime? left, DateTime? right) {
    if (left == null || right == null) return null;
    return left.isBefore(right) ? left : right;
  }

  List<ComicVersionPageMapping> composeMappings(
    List<ComicVersionRelation> path,
  ) {
    if (path.isEmpty || path.any((relation) => relation.pageMappings.isEmpty)) {
      return const <ComicVersionPageMapping>[];
    }
    var current = List<ComicVersionPageMapping>.of(path.first.pageMappings);
    for (var edge = 1; edge < path.length; edge++) {
      final next = path[edge];
      final composed = <ComicVersionPageMapping>[];
      for (final left in current) {
        for (final right in next.pageMappings) {
          if (left.successorChapterId != right.predecessorChapterId ||
              left.successorPageCount != right.predecessorPageCount) {
            continue;
          }
          final revisionChainMatches =
              left.successorSourceRevision != null &&
              left.successorSourceRevision == right.predecessorSourceRevision;
          // Anchor indexes prove each affine edge as a whole; they are not a
          // per-page allow-list. A composed mapping is therefore eligible when
          // both edges carry anchor proof and the intermediate revision joins
          // exactly. Keep the left-edge anchors as diagnostic provenance in
          // the composed predecessor index space.
          final composedProof = revisionChainMatches &&
                  left.verifiedPredecessorPageIndexes.isNotEmpty &&
                  right.verifiedPredecessorPageIndexes.isNotEmpty
              ? left.verifiedPredecessorPageIndexes
              : const <int>[];
          composed.add(
            ComicVersionPageMapping(
              predecessorChapterId: left.predecessorChapterId,
              successorChapterId: right.successorChapterId,
              predecessorPageCount: left.predecessorPageCount,
              successorPageCount: right.successorPageCount,
              successorOffset: left.successorOffset + right.successorOffset,
              predecessorSourceRevision: left.predecessorSourceRevision,
              successorSourceRevision: right.successorSourceRevision,
              verifiedPredecessorPageIndexes: composedProof,
              verifiedAt: earlierVerifiedAt(left.verifiedAt, right.verifiedAt),
            ),
          );
        }
      }
      current = composed;
      if (current.isEmpty) break;
    }
    return List<ComicVersionPageMapping>.unmodifiable(current);
  }

  for (final sourceEntry in nodesBySource.entries) {
    final sourceId = sourceEntry.key;
    for (final comicId in sourceEntry.value) {
      final start = node(sourceId, comicId);
      if (!visited.add(start)) continue;
      final component = <String>{comicId};
      final pending = <String>[start];
      while (pending.isNotEmpty) {
        final currentNode = pending.removeLast();
        for (final neighbor in undirected[currentNode] ?? const <String>{}) {
          if (!visited.add(neighbor)) continue;
          final separator = neighbor.indexOf('\u0000');
          component.add(neighbor.substring(separator + 1));
          pending.add(neighbor);
        }
      }

      final latestCandidates = <String>[
        for (final member in component)
          if ((outgoing[node(sourceId, member)] ?? const <ComicVersionRelation>[])
              .where((relation) => component.contains(relation.successorComicId))
              .isEmpty)
            member,
      ];
      final latestKnown = latestCandidates.length == 1
          ? latestCandidates.single
          : null;
      final shelfMembers = <String>[
        for (final member in component)
          if (shelfKeys.contains(node(sourceId, member))) member,
      ];
      final downloadMembers = <String>[
        for (final member in component)
          if (downloadKeys.contains(node(sourceId, member))) member,
      ];
      final shelfHead = dominantHead(sourceId, shelfMembers);
      final downloadHead = dominantHead(sourceId, downloadMembers);

      DateTime? latestKnownDiscoveredAt;
      if (latestKnown != null && component.length > 1) {
        for (final relation in history) {
          if (relation.sourceId != sourceId ||
              !component.contains(relation.predecessorComicId) ||
              !component.contains(relation.successorComicId)) {
            continue;
          }
          final discoveredAt = relation.discoveredAt;
          if (discoveredAt != null &&
              (latestKnownDiscoveredAt == null ||
                  discoveredAt.isAfter(latestKnownDiscoveredAt))) {
            latestKnownDiscoveredAt = discoveredAt;
          }
        }
      }

      final shelfBaselineMembers = shelfHead == null
          ? const <String>{}
          : <String>{
              for (final member in component)
                if (reaches(sourceId, member, shelfHead)) member,
            };
      final downloadBaselineMembers = downloadHead == null
          ? const <String>{}
          : <String>{
              for (final member in component)
                if (reaches(sourceId, member, downloadHead)) member,
            };
      families.add(
        ComicVersionFamilyBaseline(
          sourceId: sourceId,
          memberComicIds: component,
          latestKnownComicId: latestKnown,
          latestKnownDiscoveredAt: latestKnownDiscoveredAt,
          shelfHeadComicId: shelfHead,
          downloadHeadComicId: downloadHead,
          shelfBaselineComicIds: shelfBaselineMembers,
          downloadBaselineComicIds: downloadBaselineMembers,
        ),
      );

      if (downloadHead == null) continue;
      for (final member in component) {
        if (member == downloadHead || !reaches(sourceId, member, downloadHead)) {
          continue;
        }
        final path = uniquePath(sourceId, member, downloadHead);
        if (path == null || path.isEmpty) continue;
        DateTime? discoveredAt;
        for (final relation in path) {
          final candidate = relation.discoveredAt;
          if (candidate != null &&
              (discoveredAt == null || candidate.isAfter(discoveredAt))) {
            discoveredAt = candidate;
          }
        }
        directDownloadRelations.add(
          ComicVersionRelation(
            sourceId: sourceId,
            predecessorComicId: member,
            successorComicId: downloadHead,
            predecessorTitle: path.first.predecessorTitle,
            discoveredAt: discoveredAt,
            pageMappings: composeMappings(path),
          ),
        );
      }
    }
  }

  String firstMember(ComicVersionFamilyBaseline family) {
    final members = family.memberComicIds.toList()..sort();
    return members.first;
  }

  families.sort((left, right) {
    final source = left.sourceId.compareTo(right.sourceId);
    if (source != 0) return source;
    return firstMember(left).compareTo(firstMember(right));
  });
  directDownloadRelations.sort((left, right) {
    final source = left.sourceId.compareTo(right.sourceId);
    if (source != 0) return source;
    final predecessor = left.predecessorComicId.compareTo(right.predecessorComicId);
    if (predecessor != 0) return predecessor;
    return left.successorComicId.compareTo(right.successorComicId);
  });
  return ComicVersionBaselineProjection(
    families: families,
    downloadHeadRelations: directDownloadRelations,
  );
}
