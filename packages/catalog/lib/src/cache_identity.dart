import 'source_catalog.dart';

/// Delimiter-safe, versioned cache-key encoder.
///
/// Persistent cache identities must not depend on display metadata or on
/// separators that may also occur inside a source locator. Existing
/// DownloadId keys intentionally keep their historical format; this encoder is
/// used by catalog/resource-cache keys introduced from dev.135 onward.
String encodeStableCacheKey(String family, Iterable<String> components) {
  if (family.isEmpty) {
    throw ArgumentError.value(family, 'family', 'must not be empty');
  }
  final out = StringBuffer('zic-key-v1:');
  void write(String value) {
    out
      ..write(value.length)
      ..write(':')
      ..write(value);
  }

  write(family);
  for (final component in components) {
    write(component);
  }
  return out.toString();
}

/// Stable logical identity for reusable responses belonging to one comic.
///
/// [comicId] is the stable durable identity for the comic namespace, not a
/// mutable runtime locator. Sources whose raw locator embeds mutable metadata
/// (notably Mihon SManga snapshots) must project their canonical same-source
/// identity before constructing durable response/artwork keys. The raw locator
/// remains available separately for plugin invocation and must never partition
/// one comic's durable artwork cache.
final class ComicResourceCacheIdentity {
  const ComicResourceCacheIdentity({
    required this.sourceId,
    required this.comicId,
  })  : assert(sourceId != ''),
        assert(comicId != '');

  factory ComicResourceCacheIdentity.fromSource(
    BrowsableComicSource source,
    String comicId,
  ) {
    final identitySource = source is CanonicalComicIdentitySource
        ? source as CanonicalComicIdentitySource
        : null;
    return ComicResourceCacheIdentity(
      sourceId: source.sourceId,
      comicId: identitySource?.canonicalComicIdentity(comicId) ?? comicId,
    );
  }

  final String sourceId;
  final String comicId;

  String get namespace => encodeStableCacheKey(
        'comic-namespace',
        <String>[sourceId, comicId],
      );

  String response(String role) => encodeStableCacheKey(
        'comic-response',
        <String>[sourceId, comicId, role],
      );
}

String sourceResourceCacheNamespace(String sourceId) =>
    encodeStableCacheKey('source-namespace', <String>[sourceId]);
