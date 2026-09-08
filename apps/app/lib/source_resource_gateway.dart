import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

bool isLegacyVeneraRuntimeLocator(String value) =>
    value.startsWith('venera-resource://');

typedef ComicSourceResolver = BrowsableComicSource? Function(String sourceId);
typedef ComicSourceReadinessWaiter = Future<void> Function(String sourceId);

/// Composition-owned gateway for source-private image resources.
///
/// UI state supplies only a source resolver. The gateway owns transport reuse,
/// legacy locator rejection and the atomic binding exposed to chapter
/// downloads. Neither Reader nor download widgets can reach source callbacks
/// or transport-pool lifecycle directly.
final class ComicSourceResourceGateway {
  ComicSourceResourceGateway({
    required ComicSourceResolver sourceForId,
    ComicSourceReadinessWaiter? waitForSource,
    SourceResourceDirectTransport? directTransport,
    String Function()? defaultUserAgentProvider,
  })  : _sourceForId = sourceForId,
        _waitForSource = waitForSource,
        _transports = ExternalPluginResourceTransportPool(
          directTransport: directTransport,
          defaultUserAgentProvider: defaultUserAgentProvider,
        );

  final ComicSourceResolver _sourceForId;
  final ComicSourceReadinessWaiter? _waitForSource;
  final ExternalPluginResourceTransportPool _transports;
  final Set<ConfigurableChapterResourceAccess> _boundDownloads =
      HashSet<ConfigurableChapterResourceAccess>.identity();
  bool _closed = false;

  ChapterResourceAccess get chapterResourceAccess {
    _requireOpen();
    return ChapterResourceAccess(
      loadBytes: loadPageBytes,
      loadBytesControlled: loadPageBytesControlled,
      openResponse: (sourceId, uri, {range, validators}) =>
          pageResponseLoaderFor(sourceId, uri)(
        range: range,
        validators: validators,
      ),
      openControlledResponse: (sourceId, uri, {
        range,
        validators,
        control,
      }) => pageControlledResponseLoaderFor(sourceId, uri)(
        range: range,
        validators: validators,
        control: control,
      ),
      selfBoundsOpen: pageOpenSelfBoundedFor,
    );
  }

  void bindTo(ChapterDownloadService downloads) {
    final configurable = downloads is ConfigurableChapterResourceAccess
        ? downloads as ConfigurableChapterResourceAccess
        : null;
    if (configurable == null) {
      // Memory/test services receive their page loader atomically at
      // construction and have no mutable source-resource binding.
      return;
    }
    configurable.setChapterResourceAccess(chapterResourceAccess);
    _boundDownloads.add(configurable);
  }

  void unbindFrom(ChapterDownloadService downloads) {
    final configurable = downloads is ConfigurableChapterResourceAccess
        ? downloads as ConfigurableChapterResourceAccess
        : null;
    if (configurable == null || !_boundDownloads.remove(configurable)) return;
    configurable.setChapterResourceAccess(null);
  }

  Future<Uint8List> loadPageBytes(String sourceId, Uri uri) {
    _requireOpen();
    return _collectResponse(pageResponseLoaderFor(sourceId, uri));
  }

  Future<Uint8List> loadPageBytesControlled(
    String sourceId,
    Uri uri, {
    TaskControl? control,
  }) {
    _requireOpen();
    final loader = pageControlledResponseLoaderFor(sourceId, uri);
    return _collectResponse(
      () => loader(control: control),
      control: control,
    );
  }

  Future<Uint8List> loadArtworkBytes({
    required ResourceCacheManager cache,
    required String sourceId,
    required String comicId,
    String? cacheComicId,
    required Uri uri,
    String contentRevision = '',
    String resourceRole = 'cover',
    ResourceCacheRetention retention = ResourceCacheRetention.transient,
  }) async {
    final encoded = await loadArtworkSource(
      cache: cache,
      sourceId: sourceId,
      comicId: comicId,
      cacheComicId: cacheComicId,
      uri: uri,
      contentRevision: contentRevision,
      resourceRole: resourceRole,
      retention: retention,
    );
    return readEncodedResourceBytes(encoded);
  }

  Future<EncodedResourceSource> loadArtworkSource({
    required ResourceCacheManager cache,
    required String sourceId,
    required String comicId,
    String? cacheComicId,
    required Uri uri,
    String contentRevision = '',
    bool awaitPersistence = false,
    bool forceRefresh = false,
    String resourceRole = 'cover',
    ResourceCacheRetention retention = ResourceCacheRetention.transient,
  }) async {
    _requireOpen();
    final requestUri = _artworkRequestUri(uri);
    final cacheRevision = _artworkRevision(contentRevision);
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
            // Persistent reads are part of the cold-start hit path even when
            // the eventual source miss writes its new response in background.
            awaitPersistence: true,
            retention: retention,
          );
    if (cached != null) {
      return cached;
    }

    // A cold Home projection may arrive before an optional external runtime
    // has published its source adapter. Keep a cache miss pending until that
    // one source-readiness transition completes; resolving the source before
    // the cache probe would make warm covers depend on plugin activation.
    await _waitForSource?.call(sourceId);
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
      retention: retention,
      loader: () => _collectArtworkResponse(
        _transports.loaderFor(source, requestUri),
      ),
    );
    return result;
  }

  String _artworkRevision(String contentRevision) => contentRevision.isEmpty
      ? comicArtworkCacheSchemaRevision
      : '$comicArtworkCacheSchemaRevision:$contentRevision';

  String _artworkResourceRole(String role, Uri uri) => role == 'cover'
      ? 'cover'
      : '$role:${_artworkBaseUri(uri)}';

  Future<Uint8List> _collectArtworkResponse(
    ExternalPluginResourceResponseLoader loader,
  ) async {
    final bytes = await _collectResponse(() => loader());
    if (!_looksLikeEncodedImage(bytes)) {
      throw const FormatException('source artwork response is not an image');
    }
    return bytes;
  }

  Future<Uint8List> _collectResponse(
    Future<ByteResponse> Function() loader, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final response = await loader();
    final builder = BytesBuilder(copy: false);
    final iterator = StreamIterator<List<int>>(response.bytes);
    var done = false;
    try {
      while (true) {
        control?.throwIfCancelled();
        final next = control == null
            ? await iterator.moveNext()
            : await Future.any<Object>(<Future<Object>>[
                iterator.moveNext().then<Object>(_GatewayNextChunk.new),
                control.whenCancelled.then<Object>(
                  (_) => const _GatewayResponseCancelled(),
                ),
              ]).then<bool>((value) {
                if (value is _GatewayResponseCancelled) {
                  throw const Failure(
                    code: ErrorCode.cancelled,
                    message: 'source response collection was cancelled',
                  );
                }
                return (value as _GatewayNextChunk).available;
              });
        if (!next) {
          done = true;
          break;
        }
        builder.add(iterator.current);
      }
      control?.throwIfCancelled();
      return builder.takeBytes();
    } on Object {
      await iterator.cancel();
      await response.discard(control: control);
      rethrow;
    } finally {
      if (!done) {
        await iterator.cancel();
      }
    }
  }

  /// Raw page-body streaming escape hatch. This intentionally bypasses the
  /// response cache because Reader/chapter bytes are owned by DownloadSession
  /// and artifact storage. Metadata/artwork callers must use cached APIs above.
  bool pageOpenSelfBoundedFor(String sourceId, Uri uri) {
    _requireOpen();
    if (isLegacyVeneraRuntimeLocator(uri.toString())) {
      return false;
    }
    final source = _sourceForId(sourceId);
    return source != null && _transports.selfBoundsOpenFor(source, uri);
  }

  ExternalPluginControlledResourceResponseLoader
      pageControlledResponseLoaderFor(
    String sourceId,
    Uri uri,
  ) {
    _requireOpen();
    if (isLegacyVeneraRuntimeLocator(uri.toString())) {
      throw StateError('已阻止打开失效的 Venera 运行时资源定位符：$uri');
    }
    return ({ByteRange? range, Validators? validators, TaskControl? control}) async {
      // Reader/cache lookup must not wait for optional plugin activation. Only
      // the real origin-open fallback needs a live source adapter. While that
      // readiness wait is still generic-open work it remains under the normal
      // watchdog; once the source appears, report the proven source/direct
      // transport bound before entering its potentially longer runtime plan.
      await _waitForSource?.call(sourceId);
      control?.throwIfCancelled();
      final source = _requireSource(sourceId, uri);
      if (_transports.selfBoundsOpenFor(source, uri) &&
          control is OpenPhaseReportingTaskControl) {
        control.markOpenSelfBounded();
      }
      return _transports.controlledLoaderFor(source, uri)(
        range: range,
        validators: validators,
        control: control,
      );
    };
  }

  ExternalPluginResourceResponseLoader pageResponseLoaderFor(
    String sourceId,
    Uri uri,
  ) {
    _requireOpen();
    if (isLegacyVeneraRuntimeLocator(uri.toString())) {
      throw StateError('已阻止打开失效的 Venera 运行时资源定位符：$uri');
    }
    return ({ByteRange? range, Validators? validators}) async {
      await _waitForSource?.call(sourceId);
      final source = _requireSource(sourceId, uri);
      return _transports.loaderFor(source, uri)(
        range: range,
        validators: validators,
      );
    };
  }

  Future<String?> verifiedPageReuseIdentity({
    required String sourceId,
    required Uri locator,
  }) {
    _requireOpen();
    if (isLegacyVeneraRuntimeLocator(locator.toString())) {
      return Future<String?>.value(null);
    }
    final source = _requireSource(sourceId, locator);
    return _transports.verifiedReuseIdentityFor(source, locator);
  }

  void close() {
    if (_closed) return;
    for (final downloads in _boundDownloads.toList(growable: false)) {
      try {
        downloads.setChapterResourceAccess(null);
      } on StateError {
        // A composition owner may already have closed its download service.
      }
    }
    _boundDownloads.clear();
    _closed = true;
    _transports.close();
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

final class _GatewayNextChunk {
  const _GatewayNextChunk(this.available);

  final bool available;
}

final class _GatewayResponseCancelled {
  const _GatewayResponseCancelled();
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
