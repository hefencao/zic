import 'cache_index.dart';

/// A database read scope, never proof that two logical pages are equivalent.
final class CacheBindingScope {
  const CacheBindingScope({required this.sourceId, required this.comicId,
    this.chapterId, this.sourceRevision});

  final String sourceId;
  final String comicId;
  final String? chapterId;
  final String? sourceRevision;

  bool contains(CacheRec record) =>
      record.id.content.sourceId == sourceId &&
      record.id.content.comicId == comicId &&
      (chapterId == null || record.id.content.chapterId == chapterId) &&
      (sourceRevision == null || record.id.sourceRevision == sourceRevision);

  @override
  bool operator ==(Object other) => other is CacheBindingScope &&
      sourceId == other.sourceId && comicId == other.comicId &&
      chapterId == other.chapterId && sourceRevision == other.sourceRevision;

  @override
  int get hashCode => Object.hash(sourceId, comicId, chapterId, sourceRevision);
}

/// Optional indexed reads. Callers still validate READY state, version proofs,
/// ambiguity and physical authority using their existing owners.
abstract interface class CacheRecordQuery {
  Future<List<CacheRec>> listScopedBindings(Iterable<CacheBindingScope> scopes);

  /// Intentionally spans comic IDs within one source, including versions that
  /// are not members of a currently selected manual download baseline.
  Future<List<CacheRec>> listIdentityBindings({required String sourceId,
    required Iterable<String> identities});
}

final RegExp _uriContentHashPattern = RegExp(r'[a-fA-F0-9]{32,64}');

/// Shared locator token projection for indexed candidate reads. It preserves
/// the existing reuse vocabulary; it does not grant cache equivalence itself.
Iterable<String> cacheUriIdentityTerms(Uri uri) sync* {
  final segments = uri.pathSegments;
  final marker = segments.indexOf('s');
  if (marker >= 0 && marker + 1 < segments.length) {
    final imageKey = segments[marker + 1].trim().toLowerCase();
    if (imageKey.isNotEmpty) yield 'eh:$imageKey';
  }
  final hash = _uriContentHashPattern
      .firstMatch(uri.toString())?.group(0)?.toLowerCase();
  if (hash != null) yield 'hash:$hash';
}

Iterable<String> cacheRecordIdentityTerms(CacheRec record) sync* {
  final checksum = record.checksum.trim().toLowerCase();
  final algorithm = record.checksumAlgorithm.trim().toLowerCase();
  if (checksum.isNotEmpty && algorithm.isNotEmpty) {
    yield 'checksum:$algorithm:$checksum';
  }
  yield* cacheUriIdentityTerms(record.id.canonicalUri);
}
