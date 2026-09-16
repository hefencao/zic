import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';

import 'runtime_limits.dart';
import 'runtime_protocol.dart';

/// Decodes one Mihon opaque protocol identity without exposing its payload to
/// presentation or storage layers.
Map<String, dynamic>? _decodeOpaqueIdentity(
  String value,
  String prefix,
  String kind,
) {
  if (!value.startsWith(prefix)) return null;
  try {
    final payload = value.substring(prefix.length);
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(payload))),
    );
    return decoded is Map<String, dynamic> && decoded['kind'] == kind
        ? decoded
        : null;
  } on Object {
    return null;
  }
}

Uri? resolveMihonComicWebUri({
  required String comicId,
  required Uri sourceWebsite,
}) {
  final decoded = _decodeOpaqueIdentity(
    comicId,
    'mihon:manga:',
    'manga',
  );
  final raw = decoded?['url'];
  if (raw is! String || raw.trim().isEmpty) return null;
  return sourceWebsite.resolve(raw.trim());
}

/// Stable same-source comparison key for Mihon manga aliases.
///
/// Mihon browse/detail models can carry different mutable title, description,
/// thumbnail and memo fields for the same URL. Those fields must remain in the
/// opaque locator used by [loadComic], but they must not create two durable
/// comics or artwork namespaces in App projections. This key is safe for
/// same-source persistence/cache aliasing and is never used as a runtime
/// request locator.
String? canonicalMihonComicIdentity({
  required String comicId,
  required Uri sourceWebsite,
}) {
  final uri = resolveMihonComicWebUri(
    comicId: comicId,
    sourceWebsite: sourceWebsite,
  );
  return uri == null ? null : _canonicalWebIdentity(uri);
}

Uri? _resolveVeneraComicWebUri({
  required String comicId,
  required Uri sourceWebsite,
}) {
  const prefix = 'venera:comic:';
  if (!comicId.startsWith(prefix)) return null;
  try {
    final payload = comicId.substring(prefix.length);
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(payload))),
    );
    if (decoded is! Map<String, dynamic>) return null;
    final raw = decoded['id'];
    if (raw is! String || raw.trim().isEmpty) return null;
    return sourceWebsite.resolve(raw.trim());
  } on Object {
    return null;
  }
}

String _canonicalWebIdentity(Uri uri) {
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    path: path,
    fragment: '',
  ).toString();
}

String? _canonicalVeneraComicIdentity({
  required String comicId,
  required Uri sourceWebsite,
}) {
  final uri = _resolveVeneraComicWebUri(
    comicId: comicId,
    sourceWebsite: sourceWebsite,
  );
  return uri == null ? null : _canonicalWebIdentity(uri);
}

/// Adapts one isolated-runtime connection to ordinary zic catalog sources.
///
/// This is the only layer that understands both the serialized runtime schema
/// and zic domain models. Runtime engines never receive Reader/session APIs.
final class ExternalPluginRuntimeSession
    implements ExternalComicPluginSession {
  ExternalPluginRuntimeSession({
    required this.plugin,
    required ExternalPluginRuntimeConnection connection,
    required ExternalPluginRuntimeLimits limits,
  })  : _connection = connection,
        _limits = limits,
        _gate = _RuntimeInvocationGate(
          limits,
          maxConcurrentInvocations:
              plugin.format == ExternalComicPluginFormat.veneraJavaScript
                  ? 1
                  : limits.maxConcurrentInvocations,
          controlledPreemptionPriorityFloor:
              plugin.format == ExternalComicPluginFormat.veneraJavaScript
                  ? 780
                  : 1 << 30,
          dynamicPreemptionPriorityThreshold:
              plugin.format == ExternalComicPluginFormat.veneraJavaScript
                  ? 1000
                  : 1 << 30,
          preemptionThreshold: 40,
        ),
        _transformGate = _RuntimeInvocationGate(
          limits,
          maxConcurrentInvocations: 1,
          controlledPreemptionPriorityFloor:
              plugin.format == ExternalComicPluginFormat.veneraJavaScript
                  ? 780
                  : 1 << 30,
          dynamicPreemptionPriorityThreshold:
              plugin.format == ExternalComicPluginFormat.veneraJavaScript
                  ? 1000
                  : 1 << 30,
          preemptionThreshold: 40,
        ) {
    limits.validate();
    final descriptors = connection.sources;
    if (descriptors.isEmpty) {
      throw StateError('external runtime exposed no sources');
    }
    final externalIds = <String>{};
    for (final descriptor in descriptors) {
      if (!externalIds.add(descriptor.externalId)) {
        throw StateError(
          'external runtime exposed duplicate source ${descriptor.externalId}',
        );
      }
    }
    _sources = List<BrowsableComicSource>.unmodifiable(
      descriptors.map(
        (descriptor) => _RuntimeBrowsableComicSource(
          format: plugin.format,
          descriptor: descriptor,
          resourceOperationTimeout: _limits.invocationTimeout,
          invoke: _invoke,
          resolveResourceInvoke: _resolveResourceInvocation,
        ),
      ),
    );
  }

  @override
  final ExternalComicPluginCatalogEntry plugin;

  final ExternalPluginRuntimeConnection _connection;
  final ExternalPluginRuntimeLimits _limits;
  final _RuntimeInvocationGate _gate;
  final _RuntimeInvocationGate _transformGate;
  late final List<BrowsableComicSource> _sources;
  int _nextRequestId = 1;
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  List<BrowsableComicSource> get sources => _sources;

  Future<Object> _invoke(
    ExternalPluginRuntimeOperation operation,
    String externalSourceId,
    Map<String, Object?> arguments, {
    TaskControl? control,
  }) async {
    final invocation = await _invokeMeasured(
      operation,
      externalSourceId,
      arguments,
      control: control,
    );
    return invocation.payload;
  }

  Future<_RuntimeInvocationResult> _invokeMeasured(
    ExternalPluginRuntimeOperation operation,
    String externalSourceId,
    Map<String, Object?> arguments, {
    TaskControl? control,
  }) async {
    if (_closed) {
      throw StateError('external plugin runtime session is closed');
    }
    _throwIfTaskCancelled(control);
    final request = ExternalPluginRuntimeRequest(
      requestId: 'request-${_nextRequestId++}',
      operation: operation,
      externalSourceId: externalSourceId,
      arguments: arguments,
    );
    late final ExternalPluginRuntimeResponse response;
    var invocationActive = false;
    final gateWaitWatch = Stopwatch()..start();
    var gateWaitMicros = 0;
    var runtimeInvocationMicros = 0;
    String? gateBlockedByOperation;
    int? gateBlockedByPriority;
    var gateBlockedByControlled = false;
    try {
      final isolatedTransform =
          operation == ExternalPluginRuntimeOperation.transformResource &&
              arguments[_isolatedModifyImageArgument] is String;
      final invocationGate = isolatedTransform ? _transformGate : _gate;
      response = await invocationGate.run(
        () {
          gateWaitWatch.stop();
          gateWaitMicros = gateWaitWatch.elapsedMicroseconds;
          final invocationWatch = Stopwatch()..start();
          _throwIfTaskCancelled(control);
          invocationActive = true;
          final operation = _connection.invoke(request);
          final taskControl = control;
          if (taskControl != null) {
            unawaited(taskControl.whenCancelled.then((_) async {
              if (invocationActive) {
                await _cancelInvocation(request.requestId);
              }
            }));
          }
          operation.then<void>(
            (_) {
              invocationActive = false;
              invocationWatch.stop();
              runtimeInvocationMicros = invocationWatch.elapsedMicroseconds;
            },
            onError: (Object _, StackTrace __) {
              invocationActive = false;
              invocationWatch.stop();
              runtimeInvocationMicros = invocationWatch.elapsedMicroseconds;
            },
          );
          return operation;
        },
        control: control,
        onPreempt: () => _cancelInvocation(request.requestId),
        debugLabel: isolatedTransform
            ? '${operation.name}:isolated'
            : operation.name,
        onQueuedBehind: (blocker) {
          gateBlockedByOperation = blocker.operation;
          gateBlockedByPriority = blocker.priority;
          gateBlockedByControlled = blocker.controlled;
        },
      );
    } on TimeoutException catch (error) {
      unawaited(_cancelInvocation(request.requestId));
      throw Failure(
        code: ErrorCode.source,
        message: 'external plugin ${operation.name} invocation timed out after '
            '${_limits.invocationTimeout.inSeconds}s',
        cause: error,
      );
    }
    _throwIfTaskCancelled(control);
    if (response.requestId != request.requestId) {
      throw Failure(
        code: ErrorCode.source,
        message: 'external plugin response request identity mismatch',
      );
    }
    final runtimeError = response.error;
    if (runtimeError != null) {
      final verificationRequired =
          runtimeError.code == 'source-verification-required';
      final runtimeCancelled = runtimeError.code == 'runtime-request-cancelled';
      throw Failure(
        code: verificationRequired
            ? ErrorCode.sourceVerificationRequired
            : runtimeCancelled
                ? ErrorCode.cancelled
                : runtimeError.retryable
                    ? ErrorCode.network
                    : ErrorCode.source,
        message: '${runtimeError.code}: ${runtimeError.message}',
        cause: runtimeError,
        details: <String, Object?>{
          ...runtimeError.details,
          'runtimeErrorCode': runtimeError.code,
          'runtimeRetryable': runtimeError.retryable,
        },
      );
    }
    final payload = response.payload;
    if (payload == null) {
      throw const Failure(
        code: ErrorCode.source,
        message: 'external plugin response payload is missing',
      );
    }
    final size = _wireSize(payload);
    if (size > _limits.maxResponseBytes) {
      throw Failure(
        code: ErrorCode.source,
        message: 'external plugin response exceeds limit: '
            '$size > ${_limits.maxResponseBytes}',
      );
    }
    return _RuntimeInvocationResult(
      payload: payload,
      gateWaitMicros: gateWaitMicros,
      runtimeInvocationMicros: runtimeInvocationMicros,
      gateBlockedByOperation: gateBlockedByOperation,
      gateBlockedByPriority: gateBlockedByPriority,
      gateBlockedByControlled: gateBlockedByControlled,
    );
  }

  Future<_RuntimeInvocationResult> _resolveResourceInvocation(
    String externalSourceId,
    Uri uri, {
    TaskControl? control,
  }) =>
      _invokeMeasured(
        ExternalPluginRuntimeOperation.resolveResource,
        externalSourceId,
        <String, Object?>{'uri': uri.toString()},
        control: control,
      );

  Future<void> _cancelInvocation(String requestId) async {
    final connection = _connection;
    if (connection is! CancellableExternalPluginRuntimeConnection) {
      return;
    }
    try {
      await connection.cancel(requestId);
    } on Object {
      // Cancellation is advisory. The original invocation Future remains the
      // authoritative owner and retains its concurrency permit until exit.
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final drained = _gate.beginClose();
    final transformDrained = _transformGate.beginClose();
    Object? closeError;
    StackTrace? closeStackTrace;
    try {
      await _connection.close();
    } on Object catch (error, stackTrace) {
      closeError = error;
      closeStackTrace = stackTrace;
    }
    await drained;
    await transformDrained;
    if (closeError != null) {
      Error.throwWithStackTrace(closeError, closeStackTrace!);
    }
  }
}

const mihonBrowserUserAgent =
    'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
    'Chrome/131 Mobile Safari/537.36';

// Generic runtime calls do not expose Reader resource-plan diagnostics.
typedef _RuntimeInvoke = Future<Object> Function(
  ExternalPluginRuntimeOperation operation,
  String externalSourceId,
  Map<String, Object?> arguments, {
  TaskControl? control,
});

// Resolve-resource alone may carry session-owned gate/runtime timing.
typedef _RuntimeResolveResourceInvoke =
    Future<_RuntimeInvocationResult> Function(
  String externalSourceId,
  Uri uri, {
  TaskControl? control,
});

const _isolatedModifyImageArgument = '__zicIsolatedModifyImage';
const _isolatedModifyImageCacheLimit = 128;

final class _RuntimeBrowsableComicSource
    implements BrowsableComicSource, ConfigurableComicSource,
        AuthenticatableComicSource, ComicWebUriSource,
        CanonicalComicIdentitySource, ComicWebViewRequestSource,
        ComicVersionSource, ControlledComicVersionSource,
        ComicPreviewSource, ComicCommentSource,
        SectionedBrowsableComicSource,
        FilterableBrowsableComicSource,
        ControlledComicSource,
        ResolvableComicResourceSource, ControlledResolvableComicResourceSource,
        BoundedComicResourceSource,
        RetryableComicResourceSource, ControlledRetryableComicResourceSource,
        RefreshableComicResourceSource, ControlledRefreshableComicResourceSource,
        ControlledComicResourceSource,
        TransformingComicResourceSource, ControlledTransformingComicResourceSource,
        ComicResourceTransportGenerationSource {
  _RuntimeBrowsableComicSource({
    required ExternalComicPluginFormat format,
    required ExternalPluginRuntimeSourceDescriptor descriptor,
    required Duration resourceOperationTimeout,
    required _RuntimeInvoke invoke,
    required _RuntimeResolveResourceInvoke resolveResourceInvoke,
  })  : _format = format,
        _browserUserAgent = descriptor.browserUserAgent,
        _supportsComicPreview = descriptor.supportsComicPreview,
        _supportsComicComments = descriptor.supportsComicComments,
        _externalId = descriptor.externalId,
        _resourceOperationTimeout = resourceOperationTimeout,
        _invoke = invoke,
        _resolveResourceInvoke = resolveResourceInvoke,
        sourceId = '${_sourcePrefix(format)}${descriptor.externalId}',
        descriptor = ComicSourceDescriptor(
          sourceId: '${_sourcePrefix(format)}${descriptor.externalId}',
          name: descriptor.name,
          language: descriptor.language,
          website: descriptor.website,
          supportsSearch: descriptor.supportsSearch,
          contentRatings: descriptor.contentRatings,
        );

  final ExternalComicPluginFormat _format;
  final Duration _resourceOperationTimeout;

  @override
  Duration get resourceOperationTimeout => _resourceOperationTimeout;
  final String? _browserUserAgent;
  final bool _supportsComicPreview;
  final bool _supportsComicComments;
  final String _externalId;
  final _RuntimeInvoke _invoke;
  final _RuntimeResolveResourceInvoke _resolveResourceInvoke;
  final Map<Uri, Future<Uint8List>> _resourceLoads =
      <Uri, Future<Uint8List>>{};
  final Map<Uri, String> _isolatedModifyImages = <Uri, String>{};
  Object _resourceTransportGenerationIdentity = Object();

  @override
  Object get resourceTransportGenerationIdentity =>
      _resourceTransportGenerationIdentity;

  @override
  final String sourceId;

  @override
  final ComicSourceDescriptor descriptor;

  @override
  Uri? resolveComicWebUri(String comicId) => switch (_format) {
        ExternalComicPluginFormat.mihonExtension => resolveMihonComicWebUri(
            comicId: comicId,
            sourceWebsite: descriptor.website,
          ),
        ExternalComicPluginFormat.veneraJavaScript =>
          _resolveVeneraComicWebUri(
            comicId: comicId,
            sourceWebsite: descriptor.website,
          ),
      };

  @override
  String canonicalComicIdentity(String comicId) => switch (_format) {
        ExternalComicPluginFormat.mihonExtension =>
          canonicalMihonComicIdentity(
                comicId: comicId,
                sourceWebsite: descriptor.website,
              ) ??
              comicId,
        ExternalComicPluginFormat.veneraJavaScript =>
          _canonicalVeneraComicIdentity(
                comicId: comicId,
                sourceWebsite: descriptor.website,
              ) ??
              comicId,
      };

  @override
  ComicWebViewRequest webViewRequest(Uri url) => ComicWebViewRequest(
        url: url,
        userAgent: _browserUserAgent ?? switch (_format) {
          ExternalComicPluginFormat.mihonExtension => mihonBrowserUserAgent,
          ExternalComicPluginFormat.veneraJavaScript => null,
        },
      );

  Future<Object> _invokeSourceRead(
    ExternalPluginRuntimeOperation operation,
    String externalSourceId,
    Map<String, Object?> arguments, {
    TaskControl? control,
  }) async {
    try {
      return await _invoke(
        operation,
        externalSourceId,
        arguments,
        control: control,
      );
    } on Failure catch (error) {
      final replayEligible =
          _format == ExternalComicPluginFormat.veneraJavaScript &&
              error.code == ErrorCode.network &&
              error.details['sourceReadReplayEligible'] == true;
      if (!replayEligible) rethrow;
    }
    _throwIfTaskCancelled(control);
    return _invoke(
      operation,
      externalSourceId,
      <String, Object?>{
        ...arguments,
        'freshNetwork': true,
      },
      control: control,
    );
  }

  @override
  Future<List<SourceBrowseSection>> loadBrowseSections() async {
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadBrowseSections,
      _externalId,
      const <String, Object?>{},
    );
    return _list(payload, 'browse sections').map((value) {
      final section = _map(value, 'browse section');
      return SourceBrowseSection(
        sectionId: _string(section, 'sectionId'),
        label: _string(section, 'label'),
      );
    }).toList(growable: false);
  }

  @override
  Future<List<SourceSearchFilterNode>> loadSearchFilters() async {
    if (_format != ExternalComicPluginFormat.mihonExtension) {
      return const <SourceSearchFilterNode>[];
    }
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadSearchFilters,
      _externalId,
      const <String, Object?>{},
    );
    return _list(payload, 'search filters')
        .map(_sourceSearchFilterNode)
        .toList(growable: false);
  }

  Future<SourceBrowsePage> _browse({
    required String query,
    required int offset,
    required int limit,
    String? sectionId,
    SourceSearchFilterState filterState = const <String, Object?>{},
    bool useFilters = false,
  }) async {
    if (offset < 0 || limit <= 0) {
      throw ArgumentError('browse offset/limit are invalid');
    }
    final payload = await _invokeSourceRead(
      ExternalPluginRuntimeOperation.browse,
      _externalId,
      <String, Object?>{
        'query': query,
        'offset': offset,
        'limit': limit,
        'sectionId': sectionId,
        'filterState': Map<String, Object?>.from(filterState),
        'useFilters': useFilters,
      },
    );
    final message = _map(payload, 'browse result');
    final items = _list(message['items'], 'browse items').map((value) {
      final item = _map(value, 'browse item');
      return SourceComicSummary(
        sourceId: sourceId,
        comicId: _string(item, 'comicId'),
        title: _string(item, 'title'),
        authors: _stringList(item['authors'], 'authors'),
        tags: _optionalStringList(item['tags'], 'tags'),
        coverUri: _optionalUri(item['coverUri'], 'coverUri'),
        description: _optionalString(item['description'], 'description'),
        contentRating: _contentRating(item['contentRating']),
      );
    }).toList(growable: false);
    final resultOffset = _nonNegativeInt(message, 'offset');
    if (resultOffset != offset) {
      throw const FormatException('runtime browse offset mismatch');
    }
    return SourceBrowsePage(
      items: items,
      offset: resultOffset,
      hasMore: _bool(message, 'hasMore'),
    );
  }

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      _browse(
        query: query,
        offset: offset,
        limit: limit,
      );

  @override
  Future<SourceBrowsePage> browseWithFilters({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
  }) =>
      _browse(
        query: query,
        offset: offset,
        limit: limit,
        sectionId: sectionId,
        filterState: filterState,
        useFilters: true,
      );

  @override
  Future<SourceBrowsePage> browseSection(
    String sectionId, {
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      _browse(
        query: query,
        offset: offset,
        limit: limit,
        sectionId: sectionId,
      );

  @override
  bool get supportsComicVersions =>
      _format == ExternalComicPluginFormat.veneraJavaScript;

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async {
    return findComicVersionsControlled(comicId);
  }

  @override
  Future<List<SourceComicVersion>> findComicVersionsControlled(
    String comicId, {
    TaskControl? control,
  }) async {
    if (!supportsComicVersions) {
      return const <SourceComicVersion>[];
    }
    final uri = resolveComicWebUri(comicId);
    if (uri == null || !_isVeneraGndGalleryUri(uri)) {
      return const <SourceComicVersion>[];
    }
    // VibeVenera discovers E-Hentai successors from the current page's
    // #gnd relation instead of issuing a title search. Reuse the existing
    // Venera resource channel so its WebView cookie/session context remains
    // available, while keeping opaque comic IDs inside this adapter.
    final html = utf8.decode(
      await loadResourceControlled(uri, control: control),
      allowMalformed: true,
    );
    return _parseVeneraComicVersions(
      sourceId: sourceId,
      baseUri: uri,
      html: html,
    );
  }

  @override
  bool get supportsComicPreview => _supportsComicPreview;

  @override
  Future<ComicPreviewPage> loadComicPreview(
    String comicId, {
    String? nextToken,
  }) async {
    if (comicId.trim().isEmpty) {
      throw ArgumentError.value(comicId, 'comicId');
    }
    if (!supportsComicPreview) {
      return ComicPreviewPage(items: const <ComicPreviewAsset>[]);
    }
    final payload = await _invokeSourceRead(
      ExternalPluginRuntimeOperation.loadComicPreview,
      _externalId,
      <String, Object?>{
        'comicId': comicId,
        'nextToken': nextToken,
      },
    );
    return _previewPage(_map(payload, 'comic preview result'));
  }

  @override
  bool get supportsComicComments => _supportsComicComments;

  @override
  Future<ComicCommentPage> loadComicComments(
    String comicId, {
    String? subId,
    required int page,
    String? replyTo,
  }) async {
    if (comicId.trim().isEmpty) {
      throw ArgumentError.value(comicId, 'comicId');
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page');
    }
    if (!supportsComicComments) {
      return ComicCommentPage(
        page: page,
        items: const <ComicComment>[],
        maxPage: page,
      );
    }
    final payload = await _invokeSourceRead(
      ExternalPluginRuntimeOperation.loadComicComments,
      _externalId,
      <String, Object?>{
        'comicId': comicId,
        'subId': subId,
        'page': page,
        'replyTo': replyTo,
      },
    );
    return _commentPage(_map(payload, 'comic comments result'));
  }

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    return loadComicControlled(comicId);
  }

  @override
  Future<ComicManifest> loadComicControlled(
    String comicId, {
    TaskControl? control,
  }) async {
    if (comicId.trim().isEmpty) {
      throw ArgumentError.value(comicId, 'comicId');
    }
    final payload = await _invokeSourceRead(
      ExternalPluginRuntimeOperation.loadComic,
      _externalId,
      <String, Object?>{'comicId': comicId},
      control: control,
    );
    final message = _map(payload, 'comic result');
    final comicValue = _map(message['comic'], 'comic');
    final resultComicId = _string(comicValue, 'comicId');
    if (resultComicId != comicId) {
      throw const FormatException('runtime comic identity mismatch');
    }
    final comic = Comic(
      comicId: resultComicId,
      sourceId: sourceId,
      title: _string(comicValue, 'title'),
      authors: _stringList(comicValue['authors'], 'authors'),
      tags: _optionalStringList(comicValue['tags'], 'tags'),
      readingDirection: _readingDirection(comicValue['readingDirection']),
      coverUri: _optionalUri(comicValue['coverUri'], 'coverUri'),
      description: _optionalString(comicValue['description'], 'description'),
      sourceSubId: _optionalString(comicValue['subId'], 'subId'),
      createdAt: _optionalDateTime(comicValue['createdAt'], 'createdAt'),
      updatedAt: _optionalDateTime(comicValue['updatedAt'], 'updatedAt'),
    );
    final chapters = _list(message['chapters'], 'chapters')
        .map((value) => _chapter(_map(value, 'chapter'), comicId))
        .toList(growable: false);
    final chapterIds = chapters.map((chapter) => chapter.chapterId).toSet();
    if (chapterIds.length != chapters.length) {
      throw const FormatException('runtime comic contains duplicate chapters');
    }
    return ComicManifest(
      comic: comic,
      chapters: chapters,
      preview: _optionalPreviewPage(message['preview']),
      comments: _optionalCommentPage(message['comments']),
    );
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    return loadChapterControlled(chapterId);
  }

  @override
  Future<ChapterManifest> loadChapterControlled(
    String chapterId, {
    TaskControl? control,
  }) async {
    if (chapterId.trim().isEmpty) {
      throw ArgumentError.value(chapterId, 'chapterId');
    }
    final payload = await _invokeSourceRead(
      ExternalPluginRuntimeOperation.loadChapter,
      _externalId,
      <String, Object?>{'chapterId': chapterId},
      control: control,
    );
    final message = _map(payload, 'chapter result');
    final comicId = _string(message, 'comicId');
    final reportedChapter =
        _chapter(_map(message['chapter'], 'chapter'), comicId);
    if (reportedChapter.chapterId != chapterId) {
      throw const FormatException('runtime chapter identity mismatch');
    }
    final pages = _list(message['pages'], 'pages').map((value) {
      final page = _map(value, 'page');
      final resultChapterId = _string(page, 'chapterId');
      if (resultChapterId != chapterId) {
        throw const FormatException('runtime page chapter identity mismatch');
      }
      return PageAsset(
        pageId: _string(page, 'pageId'),
        chapterId: resultChapterId,
        index: _nonNegativeInt(page, 'index'),
        uri: _uri(page['uri'], 'uri'),
        width: _optionalPositiveInt(page['width'], 'width'),
        height: _optionalPositiveInt(page['height'], 'height'),
        byteLength: _optionalNonNegativeInt(page['byteLength'], 'byteLength'),
        contentKindHint: _contentKind(page['contentKindHint']),
        animatedHint: _optionalBool(page['animatedHint']) ?? false,
        checksum: _optionalString(page['checksum'], 'checksum'),
        checksumAlgorithm:
            _optionalString(page['checksumAlgorithm'], 'checksumAlgorithm'),
      );
    }).toList(growable: false);
    if (pages.isEmpty) {
      throw const FormatException('runtime chapter contains no readable pages');
    }
    final chapter = reportedChapter.pageCount == pages.length
        ? reportedChapter
        : Chapter(
            chapterId: reportedChapter.chapterId,
            comicId: reportedChapter.comicId,
            title: reportedChapter.title,
            sequence: reportedChapter.sequence,
            pageCount: pages.length,
            sourceRevision: reportedChapter.sourceRevision,
            publishedAt: reportedChapter.publishedAt,
          );
    return ChapterManifest(
      sourceId: sourceId,
      comicId: comicId,
      chapter: chapter,
      pages: pages,
      readingDirection: _readingDirection(message['readingDirection']),
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) =>
      loadResourceControlled(uri);

  @override
  Future<Uint8List> loadResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) {
    if (!uri.hasScheme) {
      throw ArgumentError.value(uri, 'uri', 'must be absolute');
    }
    if (_format == ExternalComicPluginFormat.veneraJavaScript &&
        uri.toString().startsWith('venera-resource://')) {
      throw StateError(
        'legacy Venera runtime locator must be refreshed before resource load',
      );
    }
    _throwIfTaskCancelled(control);
    // Controlled Reader/download work is never coalesced with another task's
    // runtime Future. A current page must not inherit a prefetch task's
    // cancellation or its place in the single Venera invocation queue.
    if (control != null) {
      return _loadResource(uri, control: control);
    }
    final existing = _resourceLoads[uri];
    if (existing != null) {
      return existing;
    }
    late final Future<Uint8List> load;
    load = _loadResource(uri).whenComplete(() {
      if (identical(_resourceLoads[uri], load)) {
        _resourceLoads.remove(uri);
      }
    });
    _resourceLoads[uri] = load;
    return load;
  }

  Future<Uint8List> _loadResource(
    Uri uri, {
    TaskControl? control,
  }) async {
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadResource,
      _externalId,
      <String, Object?>{'uri': uri.toString()},
      control: control,
    );
    if (payload is! Uint8List) {
      throw const FormatException(
        'runtime resource result must be a binary payload',
      );
    }
    return payload;
  }

  @override
  bool get supportsResourceTransformation =>
      _format == ExternalComicPluginFormat.veneraJavaScript;

  @override
  Future<Uint8List> transformResource(Uri uri, Uint8List bytes) =>
      transformResourceControlled(uri, bytes);

  @override
  Future<Uint8List> transformResourceControlled(
    Uri uri,
    Uint8List bytes, {
    TaskControl? control,
  }) async {
    final isolatedModifyImage = _isolatedModifyImages[uri];
    if (isolatedModifyImage != null) {
      try {
        final isolatedPayload = await _invoke(
          ExternalPluginRuntimeOperation.transformResource,
          _externalId,
          <String, Object?>{
            'uri': uri.toString(),
            'bytes': bytes,
            _isolatedModifyImageArgument: isolatedModifyImage,
          },
          control: control,
        );
        if (isolatedPayload is! Uint8List) {
          throw const FormatException(
            'runtime isolated transformed resource result must be a binary payload',
          );
        }
        return isolatedPayload;
      } on Failure catch (error) {
        final runtimeErrorCode = error.details['runtimeErrorCode'];
        if (runtimeErrorCode != 'venera-isolated-transform-incompatible' &&
            runtimeErrorCode != 'venera-isolated-transform-unavailable') {
          rethrow;
        }
        _isolatedModifyImages.remove(uri);
      }
    }
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.transformResource,
      _externalId,
      <String, Object?>{
        'uri': uri.toString(),
        'bytes': bytes,
      },
      control: control,
    );
    if (payload is! Uint8List) {
      throw const FormatException(
        'runtime transformed resource result must be a binary payload',
      );
    }
    return payload;
  }

  @override
  Future<ComicResourceRequest> resolveResource(Uri uri) =>
      resolveResourceControlled(uri);

  @override
  Future<ComicResourceRequest> resolveResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    final invocation = await _resolveResourceInvoke(
      _externalId,
      uri,
      control: control,
    );
    _rememberIsolatedModifyImage(
      uri,
      invocation.payload,
      'runtime resource request',
    );
    final request = _resourceRequestFromPayload(
      invocation.payload,
      'runtime resource request',
    );
    return ComicResourceRequest(
      uri: request.uri,
      method: request.method,
      headers: request.headers,
      body: request.body,
      requiresRuntimeTransform: request.requiresRuntimeTransform,
      diagnostics: <String, Object?>{
        ...request.diagnostics,
        'sourcePlanGateWaitMicros': invocation.gateWaitMicros,
        'sourcePlanRuntimeInvocationMicros':
            invocation.runtimeInvocationMicros,
        if (invocation.gateBlockedByOperation != null)
          'sourcePlanGateBlockedByOperation':
              invocation.gateBlockedByOperation!,
        if (invocation.gateBlockedByPriority != null)
          'sourcePlanGateBlockedByPriority': invocation.gateBlockedByPriority!,
        if (invocation.gateBlockedByOperation != null)
          'sourcePlanGateBlockedByControlled':
              invocation.gateBlockedByControlled,
      },
    );
  }

  @override
  Future<ComicResourceRequest?> retryResource(Uri uri) =>
      retryResourceControlled(uri);

  @override
  Future<ComicResourceRequest?> retryResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    if (_format == ExternalComicPluginFormat.mihonExtension) {
      // A failed host-side stream can mean that a deferred Mihon page URL or
      // source header has expired. Resolve a fresh request plan while keeping
      // the image body on the shared host transport path.
      return resolveResourceControlled(uri, control: control);
    }
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.retryResource,
      _externalId,
      <String, Object?>{'uri': uri.toString()},
      control: control,
    );
    final message = _map(payload, 'runtime resource retry');
    if (_optionalBool(message['available']) != true) {
      return null;
    }
    _rememberIsolatedModifyImage(
      uri,
      message['request'],
      'runtime retry resource request',
    );
    return _resourceRequestFromPayload(
      message['request'],
      'runtime retry resource request',
    );
  }

  @override
  Future<void> refreshResource(Uri uri) =>
      refreshResourceControlled(uri);

  @override
  Future<void> refreshResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    if (_format == ExternalComicPluginFormat.mihonExtension) {
      // Mihon resolveResource is already a fresh deferred page resolution.
      return;
    }
    await _invoke(
      ExternalPluginRuntimeOperation.resolveResource,
      _externalId,
      <String, Object?>{'uri': uri.toString(), 'fresh': true},
      control: control,
    );
  }

  void _rememberIsolatedModifyImage(
    Uri uri,
    Object? payload,
    String label,
  ) {
    final message = _map(payload, label);
    final script = _optionalString(
      message[_isolatedModifyImageArgument],
      _isolatedModifyImageArgument,
    );
    _isolatedModifyImages.remove(uri);
    if (script == null || script.trim().isEmpty) {
      return;
    }
    _isolatedModifyImages[uri] = script;
    while (_isolatedModifyImages.length > _isolatedModifyImageCacheLimit) {
      _isolatedModifyImages.remove(_isolatedModifyImages.keys.first);
    }
  }

  ComicResourceRequest _resourceRequestFromPayload(
    Object? payload,
    String label,
  ) {
    final message = _map(payload, label);
    final url = Uri.tryParse(_string(message, 'url'));
    if (url == null) {
      throw const FormatException('runtime resource URL is invalid');
    }
    final rawHeaders = _map(message['headers'] ?? const <String, Object?>{}, 'headers');
    final headers = <String, String>{
      for (final entry in rawHeaders.entries)
        entry.key: entry.value is String
            ? entry.value as String
            : entry.value.toString(),
    };
    final rawBody = message['body'];
    final Uint8List? body = switch (rawBody) {
      null => null,
      Uint8List value => value,
      List<int> value => Uint8List.fromList(value),
      String value => Uint8List.fromList(utf8.encode(value)),
      _ => throw const FormatException('runtime resource body is invalid'),
    };
    final rawDiagnostics = message['__zicDiagnostics'];
    final diagnostics = rawDiagnostics == null
        ? const <String, Object?>{}
        : _map(rawDiagnostics, 'runtime resource diagnostics');
    return ComicResourceRequest(
      uri: url,
      method: _optionalString(message['method'], 'method') ?? 'GET',
      headers: headers,
      body: body,
      requiresRuntimeTransform:
          _optionalBool(message['requiresRuntimeTransform']) ?? false,
      diagnostics: diagnostics,
    );
  }

  @override
  Future<List<ComicSourceSetting>> loadSettings() async {
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadSourceSettings,
      _externalId,
      const <String, Object?>{},
    );
    return _list(payload, 'source settings').map((value) {
      final setting = _map(value, 'source setting');
      final kindName = _string(setting, 'kind');
      final kind = ComicSourceSettingKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => throw FormatException(
          'unknown source setting kind: $kindName',
        ),
      );
      final rawValue = setting['value'];
      final Object normalizedValue;
      if (kind == ComicSourceSettingKind.toggle && rawValue is bool) {
        normalizedValue = rawValue;
      } else if (kind == ComicSourceSettingKind.multiSelect) {
        normalizedValue = _stringList(rawValue, 'source setting value');
      } else if (rawValue is String) {
        normalizedValue = rawValue;
      } else {
        throw const FormatException('source setting value is invalid');
      }
      final choices = _list(setting['choices'], 'source setting choices')
          .map((value) {
        final choice = _map(value, 'source setting choice');
        return ComicSourceSettingChoice(
          value: _string(choice, 'value'),
          label: _string(choice, 'label'),
        );
      });
      return ComicSourceSetting(
        key: _string(setting, 'key'),
        title: _string(setting, 'title'),
        summary: _optionalString(setting['summary'], 'summary'),
        kind: kind,
        value: normalizedValue,
        sensitive: _optionalBool(setting['sensitive']) ?? false,
        choices: choices,
      );
    }).toList(growable: false);
  }

  @override
  Future<void> updateSetting(String key, Object value) async {
    if (key.trim().isEmpty) {
      throw ArgumentError.value(key, 'key');
    }
    await _invoke(
      ExternalPluginRuntimeOperation.updateSourceSetting,
      _externalId,
      <String, Object?>{'key': key, 'value': value},
    );
    _advanceResourceTransportGeneration();
  }


  @override
  Future<ComicSourceAccount> loadAccount() async {
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadSourceAccount,
      _externalId,
      const <String, Object?>{},
    );
    final account = _map(payload, 'source account');
    return ComicSourceAccount(
      loggedIn: _bool(account, 'loggedIn'),
      supportsCredentials: _optionalBool(account['supportsCredentials']) ?? false,
      cookieFields: _stringList(account['cookieFields'], 'cookieFields'),
      loginWebsite: _optionalUri(account['loginWebsite'], 'loginWebsite'),
      registerWebsite: _optionalUri(account['registerWebsite'], 'registerWebsite'),
    );
  }

  @override
  Future<void> loginWithCredentials(String account, String password) async {
    if (account.trim().isEmpty || password.isEmpty) {
      throw ArgumentError('account and password must not be empty');
    }
    await _login('credentials', <String, Object?>{
      'account': account,
      'password': password,
    });
  }

  @override
  Future<void> loginWithCookies(Map<String, String> cookies) async {
    if (cookies.isEmpty || cookies.values.any((value) => value.trim().isEmpty)) {
      throw ArgumentError('cookie login values must not be empty');
    }
    await _login('cookies', <String, Object?>{'cookies': cookies});
  }

  @override
  Future<void> confirmWebLogin({
    String? currentUrl,
    String? title,
    Map<String, String> cookies = const <String, String>{},
    Map<String, String> localStorage = const <String, String>{},
  }) =>
      _login(
        'web',
        <String, Object?>{
          if (currentUrl != null) 'currentUrl': currentUrl,
          if (title != null) 'title': title,
          if (cookies.isNotEmpty) 'cookies': cookies,
          if (localStorage.isNotEmpty) 'localStorage': localStorage,
        },
      );

  Future<void> _login(String mode, Map<String, Object?> values) async {
    await _invoke(
      ExternalPluginRuntimeOperation.loginSourceAccount,
      _externalId,
      <String, Object?>{'mode': mode, 'values': values},
    );
    _advanceResourceTransportGeneration();
  }

  @override
  Future<void> logout() async {
    await _invoke(
      ExternalPluginRuntimeOperation.logoutSourceAccount,
      _externalId,
      const <String, Object?>{},
    );
    _advanceResourceTransportGeneration();
  }

  void _advanceResourceTransportGeneration() {
    _resourceTransportGenerationIdentity = Object();
  }
}

void _throwIfTaskCancelled(TaskControl? control) {
  if (control?.cancelled != true) return;
  throw const Failure(
    code: ErrorCode.cancelled,
    message: 'external plugin invocation was cancelled by its scheduler owner',
  );
}

final class _RuntimeInvocationResult {
  const _RuntimeInvocationResult({
    required this.payload,
    required this.gateWaitMicros,
    required this.runtimeInvocationMicros,
    required this.gateBlockedByOperation,
    required this.gateBlockedByPriority,
    required this.gateBlockedByControlled,
  });

  final Object payload;
  final int gateWaitMicros;
  final int runtimeInvocationMicros;
  final String? gateBlockedByOperation;
  final int? gateBlockedByPriority;
  final bool gateBlockedByControlled;
}

final class _RuntimeGateBlocker {
  const _RuntimeGateBlocker({
    required this.operation,
    required this.priority,
    required this.controlled,
  });

  final String? operation;
  final int? priority;
  final bool controlled;
}

final class _RuntimeInvocationWaiter {
  _RuntimeInvocationWaiter({
    required this.control,
    required this.sequence,
  });

  final TaskControl? control;
  final int sequence;
  final Completer<void> ready = Completer<void>();
  StreamSubscription<int>? prioritySubscription;
  bool granted = false;
  bool abandoned = false;

  int get priority => control?.priority ?? 0;

  void disposePrioritySubscription() {
    final subscription = prioritySubscription;
    prioritySubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }
}

final class _RuntimeActiveInvocation {
  _RuntimeActiveInvocation({
    required this.control,
    required this.onPreempt,
    required this.debugLabel,
  });

  final TaskControl? control;
  final Future<void> Function()? onPreempt;
  final String? debugLabel;
  StreamSubscription<int>? prioritySubscription;
  bool preemptRequested = false;

  void disposePrioritySubscription() {
    final subscription = prioritySubscription;
    prioritySubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }
}

final class _RuntimeInvocationGate {
  _RuntimeInvocationGate(
    this.limits, {
    required this.maxConcurrentInvocations,
    this.controlledPreemptionPriorityFloor = 1 << 30,
    this.dynamicPreemptionPriorityThreshold = 1 << 30,
    this.preemptionThreshold = 40,
  })  : assert(maxConcurrentInvocations > 0),
        assert(controlledPreemptionPriorityFloor >= 0),
        assert(dynamicPreemptionPriorityThreshold >= 0),
        assert(
          controlledPreemptionPriorityFloor >= (1 << 30) ||
              maxConcurrentInvocations == 1,
        );

  final ExternalPluginRuntimeLimits limits;
  final int maxConcurrentInvocations;
  final int controlledPreemptionPriorityFloor;
  final int dynamicPreemptionPriorityThreshold;
  final int preemptionThreshold;
  final List<_RuntimeInvocationWaiter> _waiters = <_RuntimeInvocationWaiter>[];
  Completer<void>? _drained;
  int _active = 0;
  int _nextWaiterSequence = 0;
  bool _closing = false;
  _RuntimeActiveInvocation? _controlledActive;
  _RuntimeActiveInvocation? _singleActive;

  Future<T> run<T>(
    Future<T> Function() action, {
    TaskControl? control,
    Future<void> Function()? onPreempt,
    String? debugLabel,
    void Function(_RuntimeGateBlocker blocker)? onQueuedBehind,
  }) async {
    if (_closing) {
      throw StateError('external plugin runtime is closing');
    }
    _throwIfTaskCancelled(control);
    if (_active >= maxConcurrentInvocations) {
      final active = _singleActive;
      if (active != null) {
        final activeControl = active.control;
        onQueuedBehind?.call(
          _RuntimeGateBlocker(
            operation: active.debugLabel,
            priority: activeControl?.priority,
            controlled: activeControl != null,
          ),
        );
      }
      _maybePreemptActiveForControlled(control);
      final waiter = _RuntimeInvocationWaiter(
        control: control,
        sequence: _nextWaiterSequence++,
      );
      _waiters.add(waiter);
      final taskControl = control;
      if (taskControl is PriorityObservableTaskControl) {
        var observedPriority = taskControl.priority;
        waiter.prioritySubscription = taskControl.priorityChanges.listen(
          (priority) {
            if (waiter.granted || waiter.abandoned || waiter.ready.isCompleted) {
              return;
            }
            final crossedDynamicThreshold =
                observedPriority < dynamicPreemptionPriorityThreshold &&
                    priority >= dynamicPreemptionPriorityThreshold;
            observedPriority = priority;
            if (crossedDynamicThreshold) {
              _maybePreemptActiveForControlled(waiter.control);
            }
          },
        );
      }
      if (taskControl != null) {
        unawaited(taskControl.whenCancelled.then((_) {
          if (waiter.granted || waiter.abandoned || waiter.ready.isCompleted) {
            return;
          }
          waiter.abandoned = true;
          _waiters.remove(waiter);
          waiter.disposePrioritySubscription();
          waiter.ready.completeError(
            const Failure(
              code: ErrorCode.cancelled,
              message: 'queued external plugin invocation was cancelled',
            ),
          );
        }));
      }
      await waiter.ready.future;
      if (_closing) {
        // The released invocation transferred its permit to this waiter.
        // Return it before rejecting work that lost the close race.
        _release(null);
        throw StateError('external plugin runtime is closing');
      }
      if (control?.cancelled == true) {
        // Cancellation may race with permit transfer. The permit remains real
        // until this waiter explicitly hands it on or returns it.
        _release(null);
        _throwIfTaskCancelled(control);
      }
    } else {
      _active++;
    }
    final tracksSingleActive = maxConcurrentInvocations == 1;
    final tracksControlledPreemption =
        controlledPreemptionPriorityFloor < (1 << 30) && control != null;
    final activeInvocation = tracksSingleActive || tracksControlledPreemption
        ? _RuntimeActiveInvocation(
            control: control,
            onPreempt: onPreempt,
            debugLabel: debugLabel,
          )
        : null;
    if (tracksSingleActive && activeInvocation != null) {
      _singleActive = activeInvocation;
    }
    if (tracksControlledPreemption && activeInvocation != null) {
      _controlledActive = activeInvocation;
      final taskControl = control;
      if (taskControl is PriorityObservableTaskControl) {
        var observedPriority = taskControl.priority;
        activeInvocation.prioritySubscription =
            taskControl.priorityChanges.listen((priority) {
          if (!identical(_controlledActive, activeInvocation) ||
              activeInvocation.preemptRequested) {
            observedPriority = priority;
            return;
          }
          final crossedCurrentThresholdDown =
              observedPriority >= dynamicPreemptionPriorityThreshold &&
                  priority < dynamicPreemptionPriorityThreshold;
          observedPriority = priority;
          if (!crossedCurrentThresholdDown) return;
          final waiter = _highestPriorityWaiter();
          if (waiter == null ||
              waiter.priority < dynamicPreemptionPriorityThreshold) {
            return;
          }
          _maybePreemptActiveForControlled(waiter.control);
        });
      }
    }
    late final Future<T> operation;
    try {
      _throwIfTaskCancelled(control);
      operation = action();
    } on Object {
      _release(activeInvocation);
      rethrow;
    }
    operation.then<void>(
      (_) => _release(activeInvocation),
      onError: (Object _, StackTrace __) => _release(activeInvocation),
    );
    return operation.timeout(limits.invocationTimeout);
  }

  void _maybePreemptActiveForControlled(TaskControl? incoming) {
    if (incoming == null ||
        incoming.priority < controlledPreemptionPriorityFloor) {
      return;
    }
    // A Venera runtime exposes one physical JS context. High-priority
    // scheduler-controlled resource work must therefore be able to cancel not
    // only a lower-ranked controlled request-plan, but also an unprioritized
    // generic operation (for example a Reader-post-frame metadata loadChapter)
    // that happens to own that sole context. The active invocation still keeps
    // the permit until its physical Future exits; cancellation only asks the
    // runtime to yield the context sooner.
    final active = _controlledActive ?? _singleActive;
    if (active == null || active.preemptRequested) return;
    final activeControl = active.control;
    if (activeControl != null &&
        incoming.priority - activeControl.priority < preemptionThreshold) {
      return;
    }
    final callback = active.onPreempt;
    if (callback == null) return;
    active.preemptRequested = true;
    unawaited(callback());
  }

  Future<void> beginClose() {
    if (_closing) {
      return _drained?.future ?? Future<void>.value();
    }
    _closing = true;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeLast();
      waiter.abandoned = true;
      waiter.disposePrioritySubscription();
      if (!waiter.ready.isCompleted) {
        waiter.ready.completeError(
          StateError('external plugin runtime is closing'),
        );
      }
    }
    if (_active == 0) {
      return Future<void>.value();
    }
    _drained = Completer<void>();
    return _drained!.future;
  }

  void _release(_RuntimeActiveInvocation? activeInvocation) {
    if (activeInvocation != null) {
      activeInvocation.disposePrioritySubscription();
      if (identical(_controlledActive, activeInvocation)) {
        _controlledActive = null;
      }
      if (identical(_singleActive, activeInvocation)) {
        _singleActive = null;
      }
    }
    if (!_closing) {
      final waiter = _takeHighestPriorityWaiter();
      if (waiter != null) {
        // Transfer the active permit directly. [_active] remains unchanged, so
        // a newly arriving invocation cannot steal the sole Venera context.
        waiter.granted = true;
        waiter.ready.complete();
        return;
      }
    }
    _active--;
    if (_active < 0) {
      throw StateError('external plugin invocation permit underflow');
    }
    if (_closing && _active == 0) {
      _drained?.complete();
      _drained = null;
    }
  }

  _RuntimeInvocationWaiter? _highestPriorityWaiter() {
    _RuntimeInvocationWaiter? best;
    for (final waiter in _waiters) {
      if (waiter.abandoned || waiter.control?.cancelled == true) {
        continue;
      }
      if (best == null ||
          waiter.priority > best.priority ||
          (waiter.priority == best.priority &&
              waiter.sequence < best.sequence)) {
        best = waiter;
      }
    }
    return best;
  }

  _RuntimeInvocationWaiter? _takeHighestPriorityWaiter() {
    final best = _highestPriorityWaiter();
    for (final waiter in List<_RuntimeInvocationWaiter>.of(_waiters)) {
      if (waiter.abandoned || waiter.control?.cancelled == true) {
        _waiters.remove(waiter);
        waiter.disposePrioritySubscription();
      }
    }
    if (best != null) {
      _waiters.remove(best);
      best.disposePrioritySubscription();
    }
    return best;
  }
}

String _sourcePrefix(ExternalComicPluginFormat format) => switch (format) {
      ExternalComicPluginFormat.mihonExtension => 'mihon:',
      ExternalComicPluginFormat.veneraJavaScript => 'venera:',
      };

ComicPreviewPage? _optionalPreviewPage(Object? value) {
  if (value == null) return null;
  return _previewPage(_map(value, 'comic preview'));
}

ComicPreviewPage _previewPage(Map<String, Object?> value) {
  final items = _list(value['items'], 'comic preview items').map((item) {
    final asset = _map(item, 'comic preview item');
    return ComicPreviewAsset(
      uri: _uri(asset['uri'], 'uri'),
      label: _optionalString(asset['label'], 'label'),
      width: _optionalPositiveInt(asset['width'], 'width'),
      height: _optionalPositiveInt(asset['height'], 'height'),
    );
  }).toList(growable: false);
  return ComicPreviewPage(
    items: items,
    nextToken: _optionalString(value['nextToken'], 'nextToken'),
  );
}

ComicCommentPage? _optionalCommentPage(Object? value) {
  if (value == null) return null;
  return _commentPage(_map(value, 'comic comments'));
}

ComicCommentPage _commentPage(Map<String, Object?> value) {
  final rawPage = value['page'];
  final page = rawPage == null ? 1 : _positiveInt(value, 'page');
  final items = _list(value['comments'], 'comic comments').map((item) {
    final comment = _map(item, 'comic comment');
    return ComicComment(
      id: _optionalString(comment['id'], 'id'),
      userName: _string(comment, 'userName'),
      avatarUri: _optionalUri(comment['avatar'], 'avatar'),
      content: _string(comment, 'content'),
      time: _optionalString(comment['time'], 'time'),
      replyCount: _optionalNonNegativeInt(
        comment['replyCount'],
        'replyCount',
      ),
      score: _optionalInt(comment['score'], 'score'),
      isLiked: _optionalBool(comment['isLiked']),
      voteStatus: _optionalInt(comment['voteStatus'], 'voteStatus'),
    );
  }).toList(growable: false);
  return ComicCommentPage(
    page: page,
    items: items,
    maxPage: _optionalPositiveInt(value['maxPage'], 'maxPage'),
  );
}

int _wireSize(Object? value, [int depth = 0]) {
  if (depth > 32) {
    throw const FormatException('runtime response is nested too deeply');
  }
  if (value == null) {
    return 0;
  }
  if (value is Uint8List) {
    return value.lengthInBytes;
  }
  if (value is String) {
    return utf8.encode(value).length;
  }
  if (value is bool || value is int || value is double) {
    return 8;
  }
  if (value is List<Object?>) {
    return value.fold<int>(
      0,
      (sum, item) => sum + _wireSize(item, depth + 1),
    );
  }
  if (value is Map<Object?, Object?>) {
    var size = 0;
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('runtime response map key is not a string');
      }
      size += utf8.encode(entry.key as String).length;
      size += _wireSize(entry.value, depth + 1);
    }
    return size;
  }
  throw FormatException(
    'runtime response contains unsupported ${value.runtimeType}',
  );
}

Chapter _chapter(Map<String, Object?> value, String comicId) {
  final resultComicId = _string(value, 'comicId');
  if (resultComicId != comicId) {
    throw const FormatException('runtime chapter comic identity mismatch');
  }
  return Chapter(
    chapterId: _string(value, 'chapterId'),
    comicId: resultComicId,
    title: _string(value, 'title'),
    sequence: _nonNegativeInt(value, 'sequence'),
    pageCount: _nonNegativeInt(value, 'pageCount'),
    sourceRevision: _string(value, 'sourceRevision'),
    publishedAt: _optionalDateTime(value['publishedAt'], 'publishedAt'),
  );
}

SourceSearchFilterNode _sourceSearchFilterNode(Object? value) {
  final message = _map(value, 'search filter');
  final kindName = _string(message, 'kind');
  SourceSearchFilterKind kind;
  try {
    kind = SourceSearchFilterKind.values.byName(kindName);
  } on ArgumentError {
    throw FormatException('unknown search filter kind: $kindName');
  }
  final filterId = _string(message, 'filterId');
  final label = _optionalString(message['label'], 'search filter label') ?? '';
  final options = _optionalStringList(
    message['options'],
    'search filter options',
  );
  final children = message['children'] == null
      ? const <SourceSearchFilterNode>[]
      : _list(message['children'], 'search filter children')
          .map(_sourceSearchFilterNode)
          .toList(growable: false);
  final rawValue = message['value'];
  final normalizedValue = switch (kind) {
    SourceSearchFilterKind.header ||
    SourceSearchFilterKind.separator ||
    SourceSearchFilterKind.group => null,
    SourceSearchFilterKind.checkBox => _requiredFilterBool(rawValue, filterId),
    SourceSearchFilterKind.triState || SourceSearchFilterKind.select =>
      _requiredFilterInt(rawValue, filterId),
    SourceSearchFilterKind.text =>
      rawValue is String ? rawValue : throw FormatException(
        'search filter $filterId must contain a string state',
      ),
    SourceSearchFilterKind.sort => _sortFilterValue(rawValue, filterId),
  };
  return SourceSearchFilterNode(
    filterId: filterId,
    kind: kind,
    label: label,
    options: options,
    value: normalizedValue,
    children: children,
  );
}

bool _requiredFilterBool(Object? value, String filterId) {
  if (value is bool) return value;
  throw FormatException('search filter $filterId must contain a bool state');
}

int _requiredFilterInt(Object? value, String filterId) {
  if (value is int) return value;
  throw FormatException('search filter $filterId must contain an int state');
}

Map<String, Object?>? _sortFilterValue(Object? value, String filterId) {
  if (value == null) return null;
  final state = _map(value, 'search sort state');
  final index = state['index'];
  final ascending = state['ascending'];
  if (index is! int || ascending is! bool) {
    throw FormatException('search filter $filterId has an invalid sort state');
  }
  return Map<String, Object?>.unmodifiable(
    <String, Object?>{'index': index, 'ascending': ascending},
  );
}

Map<String, Object?> _map(Object? value, String label) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    throw FormatException('$label must be an object');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, String label) {
  if (value is! List<Object?>) {
    throw FormatException('$label must be a list');
  }
  return value;
}

String _string(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String || field.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return field;
}

String? _optionalString(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$label must be a string');
  }
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

List<String> _stringList(Object? value, String label) {
  final list = _list(value, label);
  if (list.any((item) => item is! String)) {
    throw FormatException('$label must contain strings');
  }
  return List<String>.unmodifiable(list.cast<String>());
}

List<String> _optionalStringList(Object? value, String label) =>
    value == null ? const <String>[] : _stringList(value, label);

bool _bool(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! bool) {
    throw FormatException('$key must be a boolean');
  }
  return field;
}

bool? _optionalBool(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! bool) {
    throw const FormatException('optional boolean has invalid type');
  }
  return value;
}

int _nonNegativeInt(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! int || field < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return field;
}

int _positiveInt(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! int || field < 1) {
    throw FormatException('$key must be a positive integer');
  }
  return field;
}

int? _optionalInt(Object? value, String label) {
  if (value == null) return null;
  if (value is! int) {
    throw FormatException('$label must be an integer');
  }
  return value;
}

int? _optionalPositiveInt(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! int || value <= 0) {
    throw FormatException('$label must be a positive integer');
  }
  return value;
}

int? _optionalNonNegativeInt(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! int || value < 0) {
    throw FormatException('$label must be a non-negative integer');
  }
  return value;
}

Uri _uri(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$label must be a URI string');
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) {
    throw FormatException('$label must be an absolute URI');
  }
  return uri;
}

Uri? _optionalUri(Object? value, String label) {
  if (value == null) {
    return null;
  }
  return _uri(value, label);
}

DateTime? _optionalDateTime(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$label must be an ISO-8601 string');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$label is not a valid date-time');
  }
  return parsed;
}

ReadingDirection _readingDirection(Object? value) {
  if (value is! String) {
    throw const FormatException('readingDirection must be a string');
  }
  switch (value.trim().toLowerCase()) {
    case 'ltr':
    case 'lefttoright':
    case 'left-to-right':
      return ReadingDirection.ltr;
    case 'rtl':
    case 'righttoleft':
    case 'right-to-left':
      return ReadingDirection.rtl;
    case 'vertical':
    case 'toptobottom':
    case 'top-to-bottom':
    case 'webtoon':
      return ReadingDirection.vertical;
    default:
      throw FormatException('unknown reading direction: $value');
  }
}

ContentKindHint _contentKind(Object? value) {
  if (value == null) {
    return ContentKindHint.unknown;
  }
  if (value is! String) {
    throw const FormatException('contentKindHint must be a string');
  }
  try {
    return ContentKindHint.values.byName(value);
  } on ArgumentError {
    throw FormatException('unknown content kind: $value');
  }
}

SourceContentRating _contentRating(Object? value) {
  if (value == null) {
    return SourceContentRating.safe;
  }
  if (value is! String) {
    throw const FormatException('contentRating must be a string');
  }
  try {
    return SourceContentRating.values.byName(value);
  } on ArgumentError {
    throw FormatException('unknown content rating: $value');
  }
}

bool _isVeneraGndGalleryUri(Uri uri) {
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  return segments.length >= 3 &&
      segments[0] == 'g' &&
      segments[1].isNotEmpty &&
      segments[2].isNotEmpty;
}

List<SourceComicVersion> _parseVeneraComicVersions({
  required String sourceId,
  required Uri baseUri,
  required String html,
}) {
  final opening = RegExp(
    "<([A-Za-z][A-Za-z0-9:-]*)\\b[^>]*\\bid\\s*=\\s*[\\\"']gnd[\\\"'][^>]*>",
    caseSensitive: false,
  ).firstMatch(html);
  if (opening == null) {
    return const <SourceComicVersion>[];
  }
  final tagName = opening.group(1)!;
  final closing = RegExp(
    '<(/?)${RegExp.escape(tagName)}\\b[^>]*>',
    caseSensitive: false,
  );
  var depth = 1;
  var containerEnd = html.length;
  for (final token in closing.allMatches(html, opening.end)) {
    if (token.group(1)!.isEmpty) {
      depth++;
    } else {
      depth--;
      if (depth == 0) {
        containerEnd = token.start;
        break;
      }
    }
  }
  final container = html.substring(opening.end, containerEnd);
  final anchors = RegExp(
    r'''<a\b[^>]*>[\s\S]*?</a\s*>''',
    caseSensitive: false,
  ).allMatches(container);
  final dates = RegExp(
    r'''</a\s*>\s*,\s*added\s+(\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2})?)''',
    caseSensitive: false,
  ).allMatches(container).map((match) => match.group(1)).toList();
  final versions = <SourceComicVersion>[];
  for (var index = 0; index < anchors.length; index++) {
    final anchor = anchors.elementAt(index).group(0)!;
    final href = RegExp(
      "\\bhref\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
      caseSensitive: false,
    ).firstMatch(anchor)?.group(1);
    if (href == null) {
      continue;
    }
    final resolved = Uri.tryParse(
      baseUri.resolve(_decodeHtmlEntities(href.trim())).toString(),
    );
    if (resolved == null || !resolved.path.contains('/g/')) {
      continue;
    }
    final title = _decodeHtmlEntities(
      anchor
          .replaceFirst(RegExp(r'^<a\b[^>]*>', caseSensitive: false), '')
          .replaceFirst(RegExp(r'</a\s*>$', caseSensitive: false), '')
          .replaceAll(RegExp(r'<[^>]*>'), ' '),
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    versions.add(
      SourceComicVersion(
        sourceId: sourceId,
        comicId: _encodeVeneraComicId(resolved),
        title: title,
        generation: index + 1,
        date: index < dates.length ? dates[index] : null,
      ),
    );
  }
  return List<SourceComicVersion>.unmodifiable(versions);
}

String _encodeVeneraComicId(Uri uri) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'v': 2,
            'id': uri.toString(),
          }),
        ),
      )
      .replaceAll('=', '');
  return 'venera:comic:$payload';
}

String _decodeHtmlEntities(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) => String.fromCharCode(int.parse(match.group(1)!)),
    )
    .replaceAllMapped(
      RegExp(r'&#x([0-9a-f]+);', caseSensitive: false),
      (match) => String.fromCharCode(
        int.parse(match.group(1)!, radix: 16),
      ),
    );
