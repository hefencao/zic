import 'dart:collection';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';

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
  ComicSourceResourceGateway({required ComicSourceResolver sourceForId})
      : _sourceForId = sourceForId;

  final ComicSourceResolver _sourceForId;
  final ExternalPluginResourceTransportPool _transports =
      ExternalPluginResourceTransportPool();
  final Set<ChapterDownloadService> _boundDownloads =
      HashSet<ChapterDownloadService>.identity();
  bool _closed = false;

  ChapterResourceAccess get chapterResourceAccess {
    _requireOpen();
    return ChapterResourceAccess(
      loadBytes: loadBytes,
      openResponse: (sourceId, uri, {range, validators}) =>
          responseLoaderFor(sourceId, uri)(
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

  Future<Uint8List> loadBytes(String sourceId, Uri uri) {
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
    required Uri uri,
    String revision = '',
  }) {
    _requireOpen();
    return loadCachedComicImage(
      cache: cache,
      sourceId: sourceId,
      comicId: comicId,
      imageIdentity: uri.toString(),
      revision: revision,
      loader: () => _collectResponse(responseLoaderFor(sourceId, uri)),
    );
  }

  Future<EncodedResourceSource> loadArtworkSource({
    required ResourceCacheManager cache,
    required String sourceId,
    required String comicId,
    required Uri uri,
    String revision = '',
  }) {
    _requireOpen();
    return loadCachedComicImageSource(
      cache: cache,
      sourceId: sourceId,
      comicId: comicId,
      imageIdentity: uri.toString(),
      revision: revision,
      loader: () => _collectResponse(responseLoaderFor(sourceId, uri)),
    );
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

  ExternalPluginResourceResponseLoader responseLoaderFor(
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
