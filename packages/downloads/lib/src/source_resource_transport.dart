import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

/// Composition-owned adapter between source request resolution and the
/// Reader/download streaming transport contract.
///
/// This mirrors VibeVenera's split: the source resolves ImageLoadingConfig,
/// while a shared transport streams the response into the authoritative
/// DownloadSession. Complete image bodies never cross the plugin RPC fast path.
typedef ExternalPluginResourceResponseLoader = TransportResponseLoader;
typedef ExternalPluginControlledResourceResponseLoader =
    ControlledTransportResponseLoader;

/// Optional host transport capability after request normalization.
///
/// App composition normally leaves this null and uses the shared [HttpClient].
/// Alternative hosts and owner-package tests can provide the same streaming
/// response contract without changing request-plan or DownloadSession logic.
typedef SourceResourceDirectOpen = Future<ByteResponse> Function(
  ComicResourceRequest request,
);

typedef SourceResourceControlledDirectOpen = Future<ByteResponse> Function(
  ComicResourceRequest request, {
  TaskControl? control,
});

/// Platform-owned direct media transport used after the source has resolved
/// an immutable request plan.
///
/// The scheduler remains the sole cancellation/priority owner. Implementations
/// must bind [control] for the complete response lifetime and must not create
/// their own retry or prefetch policy.
abstract interface class SourceResourceDirectTransport {
  Future<ByteResponse> open(
    ComicResourceRequest request, {
    TaskControl? control,
  });

  void close();
}

/// Direct media transport whose client/open stage has its own finite deadline.
/// Body inactivity remains a downstream DownloadJob concern.
abstract interface class SelfBoundedSourceResourceDirectTransport
    implements SourceResourceDirectTransport {}

final class ExternalPluginResourceTransportPool {
  ExternalPluginResourceTransportPool({
    SourceResourceDirectTransport? directTransport,
    SourceResourceDirectOpen? directOpen,
    SourceResourceControlledDirectOpen? controlledDirectOpen,
    String Function()? defaultUserAgentProvider,
  })  : assert(
          directTransport == null ||
              (directOpen == null && controlledDirectOpen == null),
        ),
        assert(directOpen == null || controlledDirectOpen == null),
        _directTransport = directTransport,
        _directOpen = directOpen,
        _controlledDirectOpen = controlledDirectOpen,
        _defaultUserAgentProvider = defaultUserAgentProvider;

  final SourceResourceDirectTransport? _directTransport;
  final SourceResourceDirectOpen? _directOpen;
  final SourceResourceControlledDirectOpen? _controlledDirectOpen;
  final String Function()? _defaultUserAgentProvider;
  final Map<String, _SourceResourceTransport> _transports =
      <String, _SourceResourceTransport>{};

  TransportResponseLoader loaderFor(
    BrowsableComicSource source,
    Uri locator,
  ) {
    final transport = _transportFor(source);
    return ({ByteRange? range, Validators? validators}) => transport.open(
          locator,
          range: range,
          validators: validators,
        );
  }

  bool selfBoundsOpenFor(BrowsableComicSource source, Uri locator) =>
      _transportFor(source).selfBoundsOpen(locator);

  ExternalPluginControlledResourceResponseLoader controlledLoaderFor(
    BrowsableComicSource source,
    Uri locator,
  ) {
    final transport = _transportFor(source);
    return ({ByteRange? range, Validators? validators, TaskControl? control}) =>
        transport.openControlled(
          locator,
          range: range,
          validators: validators,
          control: control,
        );
  }

  Future<String?> verifiedReuseIdentityFor(
    BrowsableComicSource source,
    Uri locator,
  ) =>
      _transportFor(source).verifiedReuseIdentity(locator);

  _SourceResourceTransport _transportFor(BrowsableComicSource source) {
    final sourceId = source.sourceId;
    final transport = _transports.putIfAbsent(
      sourceId,
      () => _SourceResourceTransport(
        source,
        _directTransport,
        _directOpen,
        _controlledDirectOpen,
        _defaultUserAgentProvider,
      ),
    );
    transport.updateSource(source);
    return transport;
  }

  void close() {
    for (final transport in _transports.values) {
      transport.close();
    }
    _transports.clear();
    _directTransport?.close();
  }
}

final class _SourceResourceTransport
    implements ControlledTransport, SelfBoundedOpenTransport {
  _SourceResourceTransport(
    this._source,
    this._directTransport,
    this._directOpen,
    this._controlledDirectOpen,
    this._defaultUserAgentProvider,
  ) {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.autoUncompress = false;
  }

  static const _requestPlanTtl = Duration(minutes: 10);
  static const _maxRequestPlans = 256;

  BrowsableComicSource _source;
  final SourceResourceDirectTransport? _directTransport;
  final SourceResourceDirectOpen? _directOpen;
  final SourceResourceControlledDirectOpen? _controlledDirectOpen;
  final String Function()? _defaultUserAgentProvider;
  final HttpClient _client = HttpClient();
  final Map<Uri, Future<ComicResourceRequest>> _requestLoads =
      <Uri, Future<ComicResourceRequest>>{};
  final LinkedHashMap<Uri, _RequestPlanEntry> _requestPlans =
      LinkedHashMap<Uri, _RequestPlanEntry>();
  final Set<Uri> _failedStreams = <Uri>{};
  int _sourceRevision = 0;

  void updateSource(BrowsableComicSource source) {
    if (identical(_source, source)) return;
    _source = source;
    _sourceRevision++;
    // Authentication/settings may have changed with the wrapper. Keep the
    // shared HttpClient and active response streams, but do not reuse plans
    // resolved by the previous runtime instance. In-flight resolution futures
    // cannot be cancelled through the source contract, so detach them and
    // prevent their late completion from repopulating the new source's cache.
    _requestLoads.clear();
    _requestPlans.clear();
    _failedStreams.clear();
  }

  @override
  bool selfBoundsOpen(Uri uri) {
    final source = _source;
    final operationTimeout = source is BoundedComicResourceSource
        ? (source as BoundedComicResourceSource).resourceOperationTimeout
        : null;
    final direct = _directTransport;
    return operationTimeout != null &&
        operationTimeout > Duration.zero &&
        direct is SelfBoundedSourceResourceDirectTransport;
  }

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) =>
      openControlled(uri, range: range, validators: validators);

  Future<String?> verifiedReuseIdentity(Uri locator) async {
    final resolved = await _resolve(locator);
    return verifiedComicResourceIdentity(resolved.request.uri);
  }

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    range?.validate();
    _throwIfTaskCancelled(control);

    final requestPlanWatch = Stopwatch()..start();
    final resolved = await _resolve(uri, control: control);
    var request = resolved.request;
    final sourcePlanDiagnostics = resolved.cacheHit
        ? const <String, Object?>{}
        : request.diagnostics;
    _throwIfTaskCancelled(control);

    var retryUsed = false;
    if (_failedStreams.remove(uri)) {
      retryUsed = true;
      request = await _retry(uri, control: control) ?? request;
      _throwIfTaskCancelled(control);
    }
    requestPlanWatch.stop();

    final hostOpenWatch = Stopwatch()..start();
    var openPath = request.requiresRuntimeTransform
        ? 'runtime-transform'
        : 'direct';
    late final ByteResponse response;
    if (request.requiresRuntimeTransform) {
      response = await _openRuntimeFallback(
        uri,
        range: range,
        validators: validators,
        control: control,
      );
    } else {
      try {
        response = await _openDirect(
          uri,
          request,
          range: range,
          validators: validators,
          control: control,
        );
      } on Failure catch (error) {
        if (error.code == ErrorCode.cancelled) rethrow;
        if (error.code != ErrorCode.network) rethrow;
        _invalidate(uri);
        if (error.details['sourceMediaProtocolMismatch'] == true) {
          openPath = 'protocol-runtime-fallback';
          response = await _openRuntimeFallback(
            uri,
            range: range,
            validators: validators,
            control: control,
          );
        } else {
          retryUsed = true;
          final retry = await _retry(uri, control: control);
          _throwIfTaskCancelled(control);
          if (retry == null) rethrow;
          final retried = await _openRetryPlan(
            uri,
            retry,
            range: range,
            validators: validators,
            control: control,
          );
          response = retried.response;
          openPath = retried.openPath;
        }
      } on IOException catch (error) {
        _throwIfTaskCancelled(control);
        _invalidate(uri);
        retryUsed = true;
        final retry = await _retry(uri, control: control);
        _throwIfTaskCancelled(control);
        if (retry != null) {
          final retried = await _openRetryPlan(
            uri,
            retry,
            range: range,
            validators: validators,
            control: control,
          );
          response = retried.response;
          openPath = retried.openPath;
        } else {
          throw Failure(
            code: ErrorCode.network,
            message: 'source resource transport failure for ${request.uri}',
            cause: error,
          );
        }
      }
    }
    hostOpenWatch.stop();
    return _withSourceOpenDiagnostics(
      response,
      requestPlanMicros: requestPlanWatch.elapsedMicroseconds,
      requestPlanCacheHit: resolved.cacheHit,
      sourcePlanDiagnostics: sourcePlanDiagnostics,
      hostOpenMicros: hostOpenWatch.elapsedMicroseconds,
      openPath: openPath,
      retryUsed: retryUsed,
    );
  }

  Future<ComicResourceRequest?> _retry(
    Uri locator, {
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    final source = _source;
    final controlled = source is ControlledRetryableComicResourceSource
        ? source as ControlledRetryableComicResourceSource
        : null;
    final replacement = controlled != null
        ? await controlled.retryResourceControlled(locator, control: control)
        : source is RetryableComicResourceSource
            ? await (source as RetryableComicResourceSource)
                .retryResource(locator)
            : null;
    _throwIfTaskCancelled(control);
    if (replacement != null) _remember(locator, replacement);
    return replacement;
  }

  Future<({ComicResourceRequest request, bool cacheHit})> _resolve(
    Uri locator, {
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    final cached = _cached(locator);
    if (cached != null) return (request: cached, cacheHit: true);
    // Controlled work must keep its own scheduler identity. Reusing another
    // task's in-flight source-plan Future would reintroduce FIFO inheritance
    // after NetLane has already promoted/cancelled roles.
    if (control == null) {
      final active = _requestLoads[locator];
      if (active != null) {
        return (request: await active, cacheHit: false);
      }
    }
    final source = _source;
    final controlled = source is ControlledResolvableComicResourceSource
        ? source as ControlledResolvableComicResourceSource
        : null;
    final resolvable = source is ResolvableComicResourceSource
        ? source as ResolvableComicResourceSource
        : null;
    if (controlled == null && resolvable == null) {
      // A legacy BrowsableComicSource that only exposes loadResource owns the
      // request/session boundary itself. Treat it as the compatibility path;
      // sending its opaque locator to the host HttpClient can hang or bypass
      // source cookies even when the source can return the bytes immediately.
      return (
        request: ComicResourceRequest(
          uri: locator,
          requiresRuntimeTransform: true,
        ),
        cacheHit: false,
      );
    }
    final sourceRevision = _sourceRevision;
    if (control != null) {
      final request = await (controlled != null
          ? controlled.resolveResourceControlled(locator, control: control)
          : resolvable!.resolveResource(locator));
      _throwIfTaskCancelled(control);
      if (_sourceRevision != sourceRevision) {
        return _resolve(locator, control: control);
      }
      _remember(locator, request);
      return (request: request, cacheHit: false);
    }
    late final Future<ComicResourceRequest> load;
    load = (controlled != null
            ? controlled.resolveResourceControlled(locator)
            : resolvable!.resolveResource(locator))
        .then((request) {
      if (_sourceRevision == sourceRevision) {
        _remember(locator, request);
      }
      return request;
    }).whenComplete(() {
      if (identical(_requestLoads[locator], load)) {
        _requestLoads.remove(locator);
      }
    });
    _requestLoads[locator] = load;
    final request = await load;
    if (_sourceRevision != sourceRevision) {
      return _resolve(locator);
    }
    return (request: request, cacheHit: false);
  }

  ComicResourceRequest? _cached(Uri locator) {
    final entry = _requestPlans.remove(locator);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.resolvedAt) > _requestPlanTtl) {
      return null;
    }
    _requestPlans[locator] = entry;
    return entry.request;
  }

  void _remember(Uri locator, ComicResourceRequest request) {
    _requestPlans.remove(locator);
    _requestPlans[locator] = _RequestPlanEntry(
      request: request,
      resolvedAt: DateTime.now(),
    );
    while (_requestPlans.length > _maxRequestPlans) {
      _requestPlans.remove(_requestPlans.keys.first);
    }
  }

  void _invalidate(Uri locator) {
    _requestPlans.remove(locator);
  }

  Future<({ByteResponse response, String openPath})> _openRetryPlan(
    Uri locator,
    ComicResourceRequest request, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    if (request.requiresRuntimeTransform) {
      return (
        response: await _openRuntimeFallback(
          locator,
          range: range,
          validators: validators,
          control: control,
        ),
        openPath: 'retry-runtime-fallback',
      );
    }
    try {
      return (
        response: await _openDirect(
          locator,
          request,
          range: range,
          validators: validators,
          control: control,
        ),
        openPath: 'retry-direct',
      );
    } on Failure catch (error) {
      if (error.code != ErrorCode.network) rethrow;
    } on IOException {
      // A source-owned OkHttp interceptor, cookie jar or TLS stack can make
      // the host request unusable. Preserve complete-body compatibility only
      // after the streaming request plan has actually failed.
    }
    return (
      response: await _openRuntimeFallback(
        locator,
        range: range,
        validators: validators,
        control: control,
      ),
      openPath: 'retry-runtime-fallback',
    );
  }

  Future<ByteResponse> _openDirect(
    Uri locator,
    ComicResourceRequest spec, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    final normalized = normalizeSourceResourceRequest(
      spec,
      range: range,
      validators: validators,
    );
    final effective = _applyDefaultUserAgent(
      normalized,
      _defaultUserAgentProvider,
    );
    final directTransport = _directTransport;
    if (directTransport != null) {
      final response = await directTransport.open(
        effective,
        control: control,
      );
      if (control?.cancelled == true) {
        await response.discard(control: control);
        _throwIfTaskCancelled(control);
      }
      return response;
    }
    final controlledDirectOpen = _controlledDirectOpen;
    if (controlledDirectOpen != null) {
      final response = await controlledDirectOpen(effective, control: control);
      if (control?.cancelled == true) {
        await response.discard(control: control);
        _throwIfTaskCancelled(control);
      }
      return response;
    }
    final directOpen = _directOpen;
    if (directOpen != null) {
      final response = await directOpen(effective);
      if (control?.cancelled == true) {
        await response.discard(control: control);
        _throwIfTaskCancelled(control);
      }
      return response;
    }
    final method = effective.method;
    final request = await _client.openUrl(method, effective.uri);
    if (control?.cancelled == true) {
      request.abort(_taskCancelledFailure());
      _throwIfTaskCancelled(control);
    }
    // Redirect/cookie state belongs to the source client. A host replay is
    // deliberately one transaction only; stateful responses fall back to the
    // source-owned compatibility path below.
    request.followRedirects = false;
    request.maxRedirects = 0;
    for (final entry in effective.headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final requestBody = effective.body;
    if (requestBody != null && requestBody.isNotEmpty) {
      request.add(requestBody);
    }
    var requestPending = true;
    final taskControl = control;
    if (taskControl != null) {
      unawaited(taskControl.whenCancelled.then((_) {
        if (requestPending) {
          request.abort(_taskCancelledFailure());
        }
      }));
    }
    late final HttpClientResponse response;
    try {
      response = await request.close();
    } finally {
      requestPending = false;
    }
    if (control?.cancelled == true) {
      await _abortHttpResponse(response);
      _throwIfTaskCancelled(control);
    }
    if (response.isRedirect) {
      await _abortHttpResponse(response);
      throw Failure(
        code: ErrorCode.network,
        message: 'source host replay requires source-owned session state for ${effective.uri}',
        details: const <String, Object?>{
          'sourceMediaProtocolMismatch': true,
          'sourceClientStateRequired': true,
        },
      );
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await _abortHttpResponse(response);
      throw Failure(
        code: ErrorCode.network,
        message: 'HTTP ${response.statusCode} for ${effective.uri}',
      );
    }
    final parsedRange = _parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    if (response.statusCode == HttpStatus.partialContent && parsedRange == null) {
      await _abortHttpResponse(response);
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: '206 response is missing a valid Content-Range header',
      );
    }
    final modifiedValue = response.headers.value(HttpHeaders.lastModifiedHeader);
    final responseBody = parsedRange != null && parsedRange.start > 0
        ? _HttpResponseBody(
            response,
            onError: () => _failedStreams.add(locator),
          )
        : await _prefetchEncodedMediaBody(
            response,
            locator: locator,
            onError: () => _failedStreams.add(locator),
            control: control,
          );
    return ByteResponse(
      bytes: responseBody.stream,
      statusCode: response.statusCode,
      rangeStart: parsedRange?.start ?? 0,
      totalLength: parsedRange?.total ??
          (response.contentLength >= 0 ? response.contentLength : null),
      validators: Validators(
        etag: response.headers.value(HttpHeaders.etagHeader),
        lastModified: _tryParseHttpDate(modifiedValue),
      ),
      rangeSupported:
          response.statusCode == HttpStatus.partialContent ||
              response.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes',
      flowControl: ByteResponseFlowControl.streamBackpressure,
      onDiscard: responseBody.abort,
    );
  }

  Future<ByteResponse> _openRuntimeFallback(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    final source = _source;
    final bytes = source is ControlledComicResourceSource
        ? await (source as ControlledComicResourceSource)
            .loadResourceControlled(uri, control: control)
        : await source.loadResource(uri);
    _throwIfTaskCancelled(control);
    if (!hasSupportedEncodedImageSignature(bytes)) {
      _invalidate(uri);
      _failedStreams.add(uri);
      throw Failure(
        code: ErrorCode.network,
        message: 'source runtime returned non-image bytes for $uri',
        details: const <String, Object?>{
          'sourceMediaProtocolMismatch': true,
          'runtimeBodyImageSignatureRejected': true,
        },
      );
    }
    final current = Validators(etag: '"runtime-${bytes.length}-${_fnv(bytes)}"');
    final canRange = range != null &&
        range.start <= bytes.length &&
        (validators == null || validators.isEmpty || validators.matches(current));
    final start = canRange ? range.start : 0;
    final requestedEnd = canRange ? range.end : null;
    final end = requestedEnd != null
        ? (requestedEnd + 1).clamp(start, bytes.length).toInt()
        : bytes.length;
    return ByteResponse(
      bytes: _chunkRuntimeBytes(Uint8List.sublistView(bytes, start, end)),
      statusCode: canRange ? HttpStatus.partialContent : HttpStatus.ok,
      rangeStart: start,
      totalLength: bytes.length,
      validators: current,
      rangeSupported: true,
      flowControl: ByteResponseFlowControl.consumerPacing,
    );
  }

  ByteResponse _withSourceOpenDiagnostics(
    ByteResponse response, {
    required int requestPlanMicros,
    required bool requestPlanCacheHit,
    required Map<String, Object?> sourcePlanDiagnostics,
    required int hostOpenMicros,
    required String openPath,
    required bool retryUsed,
  }) {
    return ByteResponse(
      bytes: response.bytes,
      statusCode: response.statusCode,
      rangeStart: response.rangeStart,
      totalLength: response.totalLength,
      validators: response.validators,
      rangeSupported: response.rangeSupported,
      disposition: response.disposition,
      bodyAuthority: response.bodyAuthority,
      flowControl: response.flowControl,
      diagnostics: <String, Object?>{
        ...response.diagnostics,
        'sourceRequestPlanMicros': requestPlanMicros,
        'sourceRequestPlanCacheHit': requestPlanCacheHit,
        ...sourcePlanDiagnostics,
        'sourceHostOpenMicros': hostOpenMicros,
        'sourceOpenPath': openPath,
        'sourceRetryUsed': retryUsed,
      },
      readDiagnostics: response.readDiagnostics,
      onDiscardControlled: response.discard,
    );
  }

  void close() {
    _sourceRevision++;
    _requestLoads.clear();
    _requestPlans.clear();
    _failedStreams.clear();
    _client.close(force: true);
  }
}

/// Stable media identity that is strong enough for temporary cross-version
/// artifact aliasing. Titles, page numbers and filenames are deliberately not
/// accepted as evidence.
String? verifiedComicResourceIdentity(Uri uri) {
  final segments = uri.pathSegments;
  final marker = segments.indexOf('s');
  if (marker >= 0 && marker + 1 < segments.length) {
    final imageKey = segments[marker + 1].trim().toLowerCase();
    if (imageKey.isNotEmpty) return 'eh:$imageKey';
  }
  final hash = RegExp(r'[a-fA-F0-9]{32,64}')
      .firstMatch(uri.toString())
      ?.group(0)
      ?.toLowerCase();
  return hash == null ? null : 'hash:$hash';
}



Failure _taskCancelledFailure() => const Failure(
      code: ErrorCode.cancelled,
      message: 'source transport request was cancelled by its scheduler owner',
    );

void _throwIfTaskCancelled(TaskControl? control) {
  if (control?.cancelled != true) return;
  throw _taskCancelledFailure();
}

ComicResourceRequest _applyDefaultUserAgent(
  ComicResourceRequest request,
  String Function()? provider,
) {
  if (_hasHeader(request.headers, HttpHeaders.userAgentHeader)) return request;
  final value = provider?.call().trim();
  if (value == null || value.isEmpty) return request;
  return ComicResourceRequest(
    uri: request.uri,
    method: request.method,
    headers: <String, String>{
      ...request.headers,
      HttpHeaders.userAgentHeader: value,
    },
    body: request.body,
    requiresRuntimeTransform: request.requiresRuntimeTransform,
    diagnostics: request.diagnostics,
  );
}

ComicResourceRequest normalizeSourceResourceRequest(
  ComicResourceRequest spec, {
  ByteRange? range,
  Validators? validators,
}) {
  range?.validate();
  final method = spec.method.trim().toUpperCase();
  final entityless = method == 'GET' || method == 'HEAD';
  final headers = <String, String>{};
  var hasAcceptEncoding = false;
  for (final entry in spec.headers.entries) {
    final lower = entry.key.toLowerCase();
    if (entityless &&
        (lower == HttpHeaders.contentLengthHeader ||
            lower == HttpHeaders.contentTypeHeader ||
            lower == HttpHeaders.transferEncodingHeader)) {
      continue;
    }
    if (lower == HttpHeaders.acceptEncodingHeader) {
      hasAcceptEncoding = true;
    }
    headers[entry.key] = entry.value;
  }
  if (!hasAcceptEncoding) {
    headers[HttpHeaders.acceptEncodingHeader] = 'identity';
  }
  if (range != null && entityless) {
    headers[HttpHeaders.rangeHeader] = range.toString();
    final ifRange = validators?.etag ??
        (validators?.lastModified == null
            ? null
            : HttpDate.format(validators!.lastModified!.toUtc()));
    if (ifRange != null) {
      headers[HttpHeaders.ifRangeHeader] = ifRange;
    }
  }
  return ComicResourceRequest(
    uri: spec.uri,
    method: method,
    headers: headers,
    body: entityless ? null : spec.body,
    requiresRuntimeTransform: spec.requiresRuntimeTransform,
    diagnostics: spec.diagnostics,
  );
}

final class _RequestPlanEntry {
  const _RequestPlanEntry({required this.request, required this.resolvedAt});

  final ComicResourceRequest request;
  final DateTime resolvedAt;
}

abstract interface class _SourceHttpResponseBody {
  Stream<List<int>> get stream;
  Future<void> Function() get abort;
}

Future<_SourceHttpResponseBody> _prefetchEncodedMediaBody(
  HttpClientResponse response, {
  required Uri locator,
  required void Function() onError,
  TaskControl? control,
}) async {
  final iterator = StreamIterator<List<int>>(response);
  final prefetched = <List<int>>[];
  final prefix = BytesBuilder(copy: false);
  var preparing = true;
  final taskControl = control;
  if (taskControl != null) {
    unawaited(taskControl.whenCancelled.then((_) async {
      if (preparing) {
        await iterator.cancel();
      }
    }));
  }
  try {
    while (prefix.length < encodedImageSniffPrefixLength &&
        await iterator.moveNext()) {
      _throwIfTaskCancelled(control);
      final chunk = iterator.current;
      if (chunk.isEmpty) continue;
      prefetched.add(chunk);
      prefix.add(chunk);
    }
    _throwIfTaskCancelled(control);
  } on Failure catch (error) {
    await iterator.cancel();
    if (error.code != ErrorCode.cancelled) onError();
    rethrow;
  } on Object {
    onError();
    await iterator.cancel();
    rethrow;
  } finally {
    preparing = false;
  }
  final bytes = prefix.takeBytes();
  if (!hasSupportedEncodedImageSignature(bytes)) {
    await iterator.cancel();
    throw Failure(
      code: ErrorCode.network,
      message: 'source host transport returned non-media bytes for $locator',
      details: const <String, Object?>{'sourceMediaProtocolMismatch': true},
    );
  }
  final body = _PrefetchedHttpResponseBody(
    iterator,
    prefetched,
    onError: onError,
  );
  // Cancellation must stay bound for the entire response lifetime, not just
  // while request.close()/the media-prefix probe is pending. Otherwise an
  // outer DownloadJob can become cancelled while the underlying HttpClient
  // response keeps consuming a socket and bandwidth in the background.
  if (taskControl != null) {
    unawaited(taskControl.whenCancelled.then((_) => body.abort()));
  }
  return body;
}

final class _PrefetchedHttpResponseBody implements _SourceHttpResponseBody {
  _PrefetchedHttpResponseBody(
    this._iterator,
    this._prefetched, {
    required void Function() onError,
  }) : _onError = onError;

  final StreamIterator<List<int>> _iterator;
  final List<List<int>> _prefetched;
  final void Function() _onError;
  bool _aborted = false;

  @override
  Stream<List<int>> get stream async* {
    var completed = false;
    try {
      for (final chunk in _prefetched) {
        if (_aborted) return;
        yield chunk;
      }
      while (!_aborted && await _iterator.moveNext()) {
        yield _iterator.current;
      }
      completed = true;
    } on Object {
      _onError();
      rethrow;
    } finally {
      // StreamIterator.cancel() on this async* body must propagate to the
      // HttpClientResponse iterator. Do not leave a preempted prefetch socket
      // alive merely because the wrapper stream itself stopped listening.
      if (!completed) {
        await _abort();
      }
    }
  }

  @override
  Future<void> Function() get abort => _abort;

  Future<void> _abort() async {
    if (_aborted) return;
    _aborted = true;
    await _iterator.cancel();
  }
}

final class _HttpResponseBody implements _SourceHttpResponseBody {
  _HttpResponseBody(
    HttpClientResponse response, {
    required void Function() onError,
  }) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? upstream;
    var aborted = false;

    Future<void> abortUpstream() async {
      if (aborted) return;
      aborted = true;
      final active = upstream;
      if (active != null) {
        await active.cancel();
      } else {
        final disposable = response.listen(
          (_) {},
          onError: (_) {},
          cancelOnError: true,
        );
        upstream = disposable;
        await disposable.cancel();
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    }

    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        if (aborted) {
          unawaited(controller.close());
          return;
        }
        upstream = response.listen(
          (chunk) {
            if (!aborted && !controller.isClosed) controller.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            onError();
            if (!aborted && !controller.isClosed) {
              controller.addError(error, stackTrace);
              unawaited(controller.close());
            }
          },
          onDone: () {
            if (!controller.isClosed) unawaited(controller.close());
          },
          cancelOnError: true,
        );
      },
      onPause: () => upstream?.pause(),
      onResume: () => upstream?.resume(),
      onCancel: abortUpstream,
    );
    stream = controller.stream;
    abort = abortUpstream;
  }

  @override
  late final Stream<List<int>> stream;
  late final Future<void> Function() abort;
}

Future<void> _abortHttpResponse(HttpClientResponse response) async {
  final subscription = response.listen(
    (_) {},
    onError: (_) {},
    cancelOnError: true,
  );
  await subscription.cancel();
}

DateTime? _tryParseHttpDate(String? value) {
  if (value == null) return null;
  try {
    return HttpDate.parse(value);
  } on FormatException {
    return null;
  }
}

final class _ParsedContentRange {
  const _ParsedContentRange(this.start, this.total);
  final int start;
  final int? total;
}

_ParsedContentRange? _parseContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
  if (match == null) return null;
  final int start;
  final int end;
  final int? total;
  try {
    start = int.parse(match.group(1)!);
    end = int.parse(match.group(2)!);
    final totalValue = match.group(3)!;
    total = totalValue == '*' ? null : int.parse(totalValue);
  } on FormatException {
    return null;
  }
  if (end < start || (total != null && total <= end)) return null;
  return _ParsedContentRange(start, total);
}

String _fnv(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}


Stream<List<int>> _chunkRuntimeBytes(Uint8List bytes) async* {
  const chunkSize = defaultTransportChunkBytes;
  for (var offset = 0; offset < bytes.lengthInBytes; offset += chunkSize) {
    final end = (offset + chunkSize).clamp(0, bytes.lengthInBytes).toInt();
    yield Uint8List.sublistView(bytes, offset, end);
  }
}

bool _hasHeader(Map<String, String> headers, String name) => headers.keys.any(
      (key) => key.toLowerCase() == name.toLowerCase(),
    );
