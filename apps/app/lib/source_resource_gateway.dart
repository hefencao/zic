import 'dart:collection';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

const comicArtworkCacheRevision = 'artwork-v2';

bool isLegacyVeneraRuntimeLocator(String value) =>
    value.startsWith('venera-resource://');

typedef ComicSourceResolver = BrowsableComicSource? Function(String sourceId);

/// Composition-owned gateway for source-private image resources.
///
/// UI state supplies only a source resolver. The gateway owns transport reuse,
/// legacy locator rejection and the atomic binding exposed to chapter
/// downloads. Neither Reader nor download widgets can reach source callbacks
/// or transport-pool lifecycle directly.
final class ComicSourceResourceGateway {
  ComicSourceResourceGateway({
    required ComicSourceResolver sourceForId,
    String Function()? defaultUserAgentProvider,
  })  : _sourceForId = sourceForId,
        _transports = ExternalPluginResourceTransportPool(
          defaultUserAgentProvider: defaultUserAgentProvider,
        );

  final ComicSourceResolver _sourceForId;
  final ExternalPluginResourceTransportPool _transports;
  final Set<ChapterDownloadService> _boundDownloads =
      HashSet<ChapterDownloadService>.identity();
  bool _closed = false;

  ChapterResourceAccess get chapterResourceAccess {
    _requireOpen();
    return ChapterResourceAccess(
      loadBytes: loadPageBytes,
      openResponse: (sourceId, uri, {range, validators}) =>
          pageResponseLoaderFor(sourceId, uri)(
        range: range,
        validators: validators,
      ),
    );
  }

  void bindTo(ChapterDownloadService downloads) {
    _setAccess(downloads, chapterResourceAccess);
    _boundDownloads.add(downloads);
  }

  void unbindFrom(ChapterDownloadService downloads) {
    if (!_boundDownloads.remove(downloads)) return;
    _setAccess(downloads, null);
  }

  Future<Uint8List> loadPageBytes(String sourceId, Uri uri) {
    _requireOpen();
    if (isLegacyVeneraRuntimeLocator(uri.toString())) {
      throw StateError('已阻止读取失效的 Venera 运行时资源定位符：$uri');
    }
    return _requireSource(sourceId, uri).loadResource(uri);
  }

  Future<Uint8List> loadArtworkBytes({
    required ResourceCacheManager cache,
    required String sourceId,
    required String comicId,
    String? cacheComicId,
    required Uri uri,
    String revision = '',
    String resourceRole = 'cover',
  }) async {
    final encoded = await loadArtworkSource(
      cache: cache,
      sourceId: sourceId,
      comicId: comicId,
      cacheComicId: cacheComicId,
      uri: uri,
      revision: revision,
      resourceRole: resourceRole,
    );
    return readEncodedResourceBytes(encoded);
  }

  Future<EncodedResourceSource> loadArtworkSource({
    required ResourceCacheManager cache,
    required String sourceId,
    required String comicId,
    String? cacheComicId,
    required Uri uri,
    String revision = '',
    bool awaitPersistence = false,
    bool forceRefresh = false,
    String resourceRole = 'cover',
  }) async {
    _requireOpen();
    final requestUri = _artworkRequestUri(uri);
    final cacheRevision = _artworkRevision(revision);
    final cacheRole = _artworkResourceRole(resourceRole, uri);
    // Do not resolve a source before these source-independent cache probes. A
    // warm cover is an immutable response and must remain available while an
    // external source/plugin is still being discovered or restored.
    final cached = forceRefresh
        ? null
        : await readCachedComicImageSource(
            cache: cache,
            sourceId: sourceId,
            comicId: cacheComicId ?? comicId,
            imageIdentity: requestUri.toString(),
            resourceRole: cacheRole,
            revision: cacheRevision,
            awaitPersistence: awaitPersistence,
          );
    if (cached != null) {
      return cached;
    }

    final source = _requireSource(sourceId, requestUri);
    // Artwork cache identity is deliberately separate from the runtime comic
    // locator. External runtimes (notably Mihon) may encode mutable metadata in
    // comicId; callers pass a persisted/source-derived canonical identity so
    // browse, details and history share one durable artwork namespace.
    final result = await loadCachedComicImageSource(
      cache: cache,
      sourceId: sourceId,
      comicId: cacheComicId ?? comicId,
      imageIdentity: requestUri.toString(),
      resourceRole: cacheRole,
      revision: cacheRevision,
      awaitPersistence: awaitPersistence,
      forceRefresh: forceRefresh,
      loader: () => _collectArtworkResponse(
        _transports.loaderFor(source, requestUri),
      ),
    );
    return result;
  }

  String _artworkRevision(String revision) => revision.isEmpty
      ? comicArtworkCacheRevision
      : '$comicArtworkCacheRevision:$revision';

  String _artworkResourceRole(String role, Uri uri) => role == 'cover'
      ? 'cover'
      : '$role:${_artworkBaseUri(uri)}';

  Future<Uint8List> _collectArtworkResponse(
    ExternalPluginResourceResponseLoader loader,
  ) async {
    final bytes = await _collectResponse(loader);
    if (!_looksLikeEncodedImage(bytes)) {
      throw const FormatException('source artwork response is not an image');
    }
    return bytes;
  }

  Future<Uint8List> _collectResponse(
    ExternalPluginResourceResponseLoader loader,
  ) async {
    final response = await loader();
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.bytes) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on Object {
      await response.discard();
      rethrow;
    }
  }

  /// Raw page-body streaming escape hatch. This intentionally bypasses the
  /// response cache because Reader/chapter bytes are owned by DownloadSession
  /// and artifact storage. Metadata/artwork callers must use cached APIs above.
  ExternalPluginResourceResponseLoader pageResponseLoaderFor(
    String sourceId,
    Uri uri,
  ) {
    _requireOpen();
    if (isLegacyVeneraRuntimeLocator(uri.toString())) {
      throw StateError('已阻止打开失效的 Venera 运行时资源定位符：$uri');
    }
    return _transports.loaderFor(_requireSource(sourceId, uri), uri);
  }

  void close() {
    if (_closed) return;
    for (final downloads in _boundDownloads.toList(growable: false)) {
      try {
        _setAccess(downloads, null);
      } on StateError {
        // A composition owner may already have closed its download service.
      }
    }
    _boundDownloads.clear();
    _closed = true;
    _transports.close();
  }

  void _setAccess(
    ChapterDownloadService downloads,
    ChapterResourceAccess? access,
  ) {
    final configurable = downloads is ConfigurableChapterResourceAccess
        ? downloads as ConfigurableChapterResourceAccess
        : null;
    if (configurable != null) {
      configurable.setChapterResourceAccess(access);
      return;
    }

    // Compatibility for third-party/test services implementing the older
    // independent capabilities. Production persistent downloads use the
    // atomic capability above and never observe a half-bound pair.
    final loader = downloads is ConfigurableChapterResourceLoader
        ? downloads as ConfigurableChapterResourceLoader
        : null;
    final transport = downloads is ConfigurableChapterResourceTransport
        ? downloads as ConfigurableChapterResourceTransport
        : null;
    loader?.setChapterResourceLoader(access?.loadBytes);
    transport?.setChapterResourceTransport(access?.openResponse);
  }

  BrowsableComicSource _requireSource(String sourceId, Uri uri) {
    final source = _sourceForId(sourceId);
    if (source == null) {
      throw StateError('漫画源 $sourceId 当前不可用，无法加载 $uri');
    }
    return source;
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('source resource gateway is closed');
    }
  }
}

Uri _artworkRequestUri(Uri uri) {
  final base = _artworkBaseUri(uri);
  return base == uri.toString() ? uri : Uri.parse(base);
}

/// Venera appends a crop descriptor to preview URLs. The descriptor changes
/// painting, not the encoded bytes, so all crops of one base URL must share
/// the response-cache entry and the network request.
String _artworkBaseUri(Uri uri) {
  final value = uri.toString();
  final marker = value.lastIndexOf('@');
  if (marker <= 0 || marker == value.length - 1) return value;
  final suffix = value.substring(marker + 1);
  if (!suffix.startsWith('x=') && !suffix.startsWith('y=')) return value;
  return value.substring(0, marker);
}

bool _looksLikeEncodedImage(Uint8List bytes) {
  bool matches(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  if (matches(0, const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return true;
  }
  if (matches(0, const <int>[0xff, 0xd8, 0xff]) ||
      matches(0, const <int>[0x47, 0x49, 0x46, 0x38]) ||
      matches(0, const <int>[0x42, 0x4d]) ||
      matches(0, const <int>[0x00, 0x00, 0x01, 0x00])) {
    return true;
  }
  if (matches(0, const <int>[0x52, 0x49, 0x46, 0x46]) &&
      matches(8, const <int>[0x57, 0x45, 0x42, 0x50])) {
    return true;
  }
  if (matches(4, const <int>[0x66, 0x74, 0x79, 0x70]) && bytes.length >= 12) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    return brand == 'avif' || brand == 'avis' || brand == 'heic' || brand == 'heix';
  }
  return false;
}
