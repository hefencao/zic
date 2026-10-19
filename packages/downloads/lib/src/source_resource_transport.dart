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
    Uri locator, {
    TaskControl? control,
  }) =>
      _transportFor(source).verifiedReuseIdentity(
        locator,
        control: control,
      );

  Future<void> refreshResourceFor(
    BrowsableComicSource source,
    Uri locator, {
    TaskControl? control,
  }) async {
    final transport = _transportFor(source);
    transport.beginFreshResourceGeneration(locator);
    final controlled = source is ControlledRefreshableComicResourceSource
        ? source as ControlledRefreshableComicResourceSource
        : null;
    if (controlled != null) {
      await controlled.refreshResourceControlled(locator, control: control);
      return;
    }
    final refreshable = source is RefreshableComicResourceSource
        ? source as RefreshableComicResourceSource
        : null;
    await refreshable?.refreshResource(locator);
  }

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
  ) : _sourceGenerationIdentity = _resourceTransportGenerationIdentity(_source) {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.autoUncompress = false;
  }

  static const _requestPlanTtl = Duration(minutes: 10);
  static const _maxRequestPlans = 256;
  static const _maxSourceSemanticRetries = 5;
  static const _maxRuntimeTransformInputBytes = 30 * 1024 * 1024;

  BrowsableComicSource _source;
  Object _sourceGenerationIdentity;
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
  final Map<Uri, int> _resourceGenerations = <Uri, int>{};
  int _sourceRevision = 0;

  void beginFreshResourceGeneration(Uri locator) {
    _resourceGenerations[locator] = (_resourceGenerations[locator] ?? 0) + 1;
    _requestLoads.remove(locator);
    _requestPlans.remove(locator);
    _failedStreams.remove(locator);
  }

  void updateSource(BrowsableComicSource source) {
    if (identical(_source, source)) return;
    final nextGenerationIdentity = _resourceTransportGenerationIdentity(source);
    final generationChanged =
        !identical(_sourceGenerationIdentity, nextGenerationIdentity);
    _source = source;
    if (!generationChanged) return;
    _sourceGenerationIdentity = nextGenerationIdentity;
    _sourceRevision++;
    // A real source/runtime generation replacement invalidates request plans
    // and in-flight resolver work. Pure presentation/cache decorators expose
    // the same transport generation identity and therefore do not evict an
    // expensive but still valid source-owned image plan.
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

  Future<String?> verifiedReuseIdentity(
    Uri locator, {
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    final resolved = await _resolve(locator, control: control);
    _throwIfTaskCancelled(control);
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
    String? verifiedReuseIdentity;
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
    var openPath = 'direct';
    if (!request.requiresRuntimeTransform) {
      verifiedReuseIdentity = verifiedComicResourceIdentity(request.uri);
    }
    late final ByteResponse response;
    try {
      final opened = await _openRequestPlan(
        uri,
        request,
        range: range,
        validators: validators,
        control: control,
      );
      response = opened.response;
      openPath = opened.openPath;
    } on Failure catch (error, stackTrace) {
      if (error.code == ErrorCode.cancelled) rethrow;
      final semanticFailure = _isSourceMediaSemanticRejection(error);
      final planReplayFailure = _isSourceResourcePlanReplayEligible(error);
      if (!semanticFailure &&
          !planReplayFailure &&
          error.code != ErrorCode.network) {
        rethrow;
      }
      if (semanticFailure &&
          error.details['sourceSemanticRetryExhausted'] == true) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      _invalidate(uri);
      retryUsed = true;
      verifiedReuseIdentity = null;
      if (planReplayFailure) {
        final ComicResourceRequest? replacement;
        try {
          replacement = await _retry(uri, control: control);
        } on Failure catch (retryError, retryStack) {
          if (retryError.code != ErrorCode.source) {
            Error.throwWithStackTrace(retryError, retryStack);
          }
          throw _sourceResourcePlanReplayUnavailableFailure(
            uri,
            cause: retryError,
          );
        }
        if (replacement == null) {
          throw _sourceResourcePlanReplayUnavailableFailure(
            uri,
            cause: error,
          );
        }
        try {
          final retried = await _openRetryPlan(
            uri,
            replacement,
            range: range,
            validators: validators,
            control: control,
          );
          response = retried.response;
          openPath = retried.openPath;
        } on Failure catch (retryError, retryStack) {
          if (!_isSourceResourcePlanReplayEligible(retryError)) {
            Error.throwWithStackTrace(retryError, retryStack);
          }
          throw _sourceResourcePlanReplayUnavailableFailure(
            uri,
            cause: retryError,
          );
        }
      } else {
        try {
          final retried = await _recoverSourceRequest(
            uri,
            initialRequestUri: request.uri,
            range: range,
            validators: validators,
            control: control,
            cause: error,
            requireRetry: semanticFailure,
          );
          response = retried.response;
          openPath = retried.openPath;
        } on _NoSourceRecoveryAvailable {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    } on IOException catch (error) {
        _throwIfTaskCancelled(control);
        _invalidate(uri);
        retryUsed = true;
        try {
          verifiedReuseIdentity = null;
          final retried = await _recoverSourceRequest(
            uri,
            initialRequestUri: request.uri,
            range: range,
            validators: validators,
            control: control,
            cause: error,
            requireRetry: false,
          );
          response = retried.response;
          openPath = retried.openPath;
        } on _NoSourceRecoveryAvailable {
          throw Failure(
            code: ErrorCode.network,
            message: 'source resource transport failure for ${request.uri}',
            cause: error,
          );
        }
    }
    hostOpenWatch.stop();
    return _withSourceOpenDiagnostics(
      response,
      locator: uri,
      control: control,
      requestPlanMicros: requestPlanWatch.elapsedMicroseconds,
      requestPlanCacheHit: resolved.cacheHit,
      sourcePlanDiagnostics: sourcePlanDiagnostics,
      hostOpenMicros: hostOpenWatch.elapsedMicroseconds,
      openPath: openPath,
      retryUsed: retryUsed,
      verifiedReuseIdentity: verifiedReuseIdentity,
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

  Future<({ByteResponse response, String openPath})> _recoverSourceRequest(
    Uri locator, {
    required Uri initialRequestUri,
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
    Object? cause,
    bool requireRetry = true,
  }) async {
    Object? lastCause = cause;
    var acceptedPlans = 0;
    var sameUrlPlans = 0;
    var changedUrlPlans = 0;
    var runtimeTransformPlans = 0;
    var freshResolvePlans = 0;
    var previousUri = initialRequestUri;
    for (var retryIndex = 0;
        retryIndex < _maxSourceSemanticRetries;
        retryIndex++) {
      final replacement = await _retry(locator, control: control);
      _throwIfTaskCancelled(control);
      if (replacement == null) {
        if (!requireRetry && retryIndex == 0) {
          throw const _NoSourceRecoveryAvailable();
        }
        // Some sources cannot manufacture a retryResource plan even though a
        // second resolveResource for the same opaque locator can produce a
        // fresh request plan. Keep this inside the current scheduler-owned
        // transport attempt: it is one bounded source-plan re-resolution, not
        // an independent network retry or Reader-owned fallback.
        if (freshResolvePlans == 0) {
          final freshResolved = await _resolve(locator, control: control);
          _throwIfTaskCancelled(control);
          freshResolvePlans++;
          try {
            return await _openRequestPlan(
              locator,
              freshResolved.request,
              range: range,
              validators: validators,
              control: control,
              pathPrefix: 'fresh-resolve-',
            );
          } on Failure catch (error) {
            if (!_isSourceMediaSemanticRejection(error)) rethrow;
            lastCause = error;
            _invalidate(locator);
          }
        }
        throw _sourceMediaSemanticFailure(
          locator,
          cause: lastCause,
          acceptedPlans: acceptedPlans,
          sameUrlPlans: sameUrlPlans,
          changedUrlPlans: changedUrlPlans,
          runtimeTransformPlans: runtimeTransformPlans,
          freshResolvePlans: freshResolvePlans,
          recoveryUnavailable: true,
        );
      }
      acceptedPlans++;
      if (_sameSemanticRequestUri(previousUri, replacement.uri)) {
        sameUrlPlans++;
      } else {
        changedUrlPlans++;
      }
      if (replacement.requiresRuntimeTransform) {
        runtimeTransformPlans++;
      }
      previousUri = replacement.uri;
      try {
        return await _openRetryPlan(
          locator,
          replacement,
          range: range,
          validators: validators,
          control: control,
        );
      } on Failure catch (error) {
        if (!_isSourceMediaSemanticRejection(error)) rethrow;
        lastCause = error;
        _invalidate(locator);
      }
    }
    throw _sourceMediaSemanticFailure(
      locator,
      cause: lastCause,
      acceptedPlans: acceptedPlans,
      sameUrlPlans: sameUrlPlans,
      changedUrlPlans: changedUrlPlans,
      runtimeTransformPlans: runtimeTransformPlans,
      recoveryUnavailable: false,
    );
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
    final resourceGeneration = _resourceGenerations[locator] ?? 0;
    bool generationChanged() =>
        _sourceRevision != sourceRevision ||
        (_resourceGenerations[locator] ?? 0) != resourceGeneration;
    if (control != null) {
      final request = await (controlled != null
          ? controlled.resolveResourceControlled(locator, control: control)
          : resolvable!.resolveResource(locator));
      _throwIfTaskCancelled(control);
      if (generationChanged()) {
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
      if (!generationChanged()) {
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
    if (generationChanged()) {
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

  Future<({ByteResponse response, String openPath})> _openRequestPlan(
    Uri locator,
    ComicResourceRequest request, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
    String pathPrefix = '',
  }) async {
    _throwIfTaskCancelled(control);
    if (request.requiresRuntimeTransform) {
      return _openRuntimeTransformPlan(
        locator,
        request,
        range: range,
        validators: validators,
        control: control,
        pathPrefix: pathPrefix,
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
        openPath: '${pathPrefix}direct',
      );
    } on Failure catch (error) {
      if (!_requiresSourceClientState(error)) rethrow;
      return (
        response: await _openRuntimeFallback(
          locator,
          range: range,
          validators: validators,
          control: control,
        ),
        openPath: '${pathPrefix}client-runtime-fallback',
      );
    }
  }

  Future<({ByteResponse response, String openPath})> _openRetryPlan(
    Uri locator,
    ComicResourceRequest request, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    try {
      return await _openRequestPlan(
        locator,
        request,
        range: range,
        validators: validators,
        control: control,
        pathPrefix: 'retry-',
      );
    } on Failure catch (error, stackTrace) {
      if (error.code != ErrorCode.network) rethrow;
      if (_isSourceMediaSemanticRejection(error)) rethrow;
      Error.throwWithStackTrace(error, stackTrace);
    } on IOException catch (error) {
      throw Failure(
        code: ErrorCode.network,
        message: 'source retry transport failure for ${request.uri}',
        cause: error,
      );
    }
  }

  Future<({ByteResponse response, String openPath})> _openRuntimeTransformPlan(
    Uri locator,
    ComicResourceRequest request, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
    String pathPrefix = '',
  }) async {
    final source = _source;
    final controlled = source is ControlledTransformingComicResourceSource
        ? source as ControlledTransformingComicResourceSource
        : null;
    final transforming = source is TransformingComicResourceSource
        ? source as TransformingComicResourceSource
        : null;
    if (transforming?.supportsResourceTransformation != true ||
        (request.uri.scheme != 'http' && request.uri.scheme != 'https')) {
      return (
        response: await _openRuntimeFallback(
          locator,
          range: range,
          validators: validators,
          control: control,
        ),
        openPath: '${pathPrefix}runtime-transform',
      );
    }

    late final ByteResponse rawResponse;
    final rawOpenWatch = Stopwatch()..start();
    try {
      rawResponse = await _openDirect(
        locator,
        request,
        control: control,
      );
      rawOpenWatch.stop();
    } on Failure catch (error) {
      rawOpenWatch.stop();
      if (!_requiresSourceClientState(error)) rethrow;
      return (
        response: await _openRuntimeFallback(
          locator,
          range: range,
          validators: validators,
          control: control,
        ),
        openPath: '${pathPrefix}transform-client-runtime-fallback',
      );
    }

    if (rawResponse.totalLength != null &&
        rawResponse.totalLength! > _maxRuntimeTransformInputBytes) {
      await rawResponse.discard(control: control);
      return (
        response: await _openRuntimeFallback(
          locator,
          range: range,
          validators: validators,
          control: control,
        ),
        openPath: '${pathPrefix}runtime-transform-large-fallback',
      );
    }
    final rawCollectWatch = Stopwatch()..start();
    final rawBytes = await _collectRuntimeTransformInput(
      rawResponse,
      control: control,
    );
    rawCollectWatch.stop();
    if (rawBytes == null) {
      return (
        response: await _openRuntimeFallback(
          locator,
          range: range,
          validators: validators,
          control: control,
        ),
        openPath: '${pathPrefix}runtime-transform-large-fallback',
      );
    }
    _throwIfTaskCancelled(control);
    Uint8List? transformed;
    ComicResourceBody? transformedBody;
    final transformWatch = Stopwatch()..start();
    try {
      final bodyTransform = source is BodyTransformingComicResourceSource
          ? source as BodyTransformingComicResourceSource : null;
      if (bodyTransform?.supportsResourceTransformBodyDelivery == true) {
        transformedBody = await bodyTransform!.transformResourceBody(
          locator, rawBytes, control: control,
        );
      } else {
        transformed = controlled != null
          ? await controlled.transformResourceControlled(
              locator,
              rawBytes,
              control: control,
            )
          : await transforming!.transformResource(locator, rawBytes);
      }
      transformWatch.stop();
    } on Object catch (error, stackTrace) {
      transformWatch.stop();
      _throwIfTaskCancelled(control);
      Error.throwWithStackTrace(
        Failure(
          code: ErrorCode.source,
          message: 'source runtime transform failed for $locator',
          cause: error,
          details: const <String, Object?>{
            'sourceMediaProtocolMismatch': true,
            'sourceMediaSemanticRejected': true,
            'runtimeTransformFailed': true,
          },
        ),
        stackTrace,
      );
    }
    final diagnostics = <String, Object?>{
      'sourceRawOpenMicros': rawOpenWatch.elapsedMicroseconds,
      'sourceRawCollectMicros': rawCollectWatch.elapsedMicroseconds,
      'sourceRuntimeTransformMicros': transformWatch.elapsedMicroseconds,
    };
    if (transformedBody != null) {
      return (
        response: await _runtimeBodyResponse(
          locator, transformedBody, range: range, validators: validators,
          control: control, semanticRetryExhausted: false,
          rejectionDetailKey: 'runtimeTransformImageSignatureRejected',
          diagnostics: diagnostics,
        ),
        openPath: '${pathPrefix}host-fetch-runtime-transform',
      );
    }
    _throwIfTaskCancelled(control);
    return (
      response: _runtimeBytesResponse(
        locator, transformed!, range: range, validators: validators,
        semanticRetryExhausted: false,
        rejectionDetailKey: 'runtimeTransformImageSignatureRejected',
        diagnostics: diagnostics,
      ),
      openPath: '${pathPrefix}host-fetch-runtime-transform',
    );
  }

  Future<Uint8List?> _collectRuntimeTransformInput(
    ByteResponse response, {
    TaskControl? control,
  }) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.bytes) {
        _throwIfTaskCancelled(control);
        builder.add(chunk);
        if (builder.length > _maxRuntimeTransformInputBytes) {
          await response.discard(control: control);
          return null;
        }
      }
      _throwIfTaskCancelled(control);
      return builder.takeBytes();
    } on Object {
      await response.discard(control: control);
      rethrow;
    }
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
    if (response.headers.value(HttpHeaders.setCookieHeader) != null) {
      await _abortHttpResponse(response);
      throw Failure(
        code: ErrorCode.network,
        message:
            'source host replay requires source-owned cookie state for ${effective.uri}',
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
    final responseBody = effective.requiresRuntimeTransform ||
            (parsedRange != null && parsedRange.start > 0)
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
    if (source is BodyDeliveringComicResourceSource &&
        (source as BodyDeliveringComicResourceSource).supportsResourceBodyDelivery) {
      final body = await (source as BodyDeliveringComicResourceSource)
          .openResourceBody(uri, control: control);
      return _runtimeBodyResponse(
        uri, body, range: range, validators: validators, control: control,
        semanticRetryExhausted: true,
        rejectionDetailKey: 'runtimeBodyImageSignatureRejected',
      );
    }
    final bytes = source is ControlledComicResourceSource
        ? await (source as ControlledComicResourceSource)
            .loadResourceControlled(uri, control: control)
        : await source.loadResource(uri);
    _throwIfTaskCancelled(control);
    return _runtimeBytesResponse(
      uri,
      bytes,
      range: range,
      validators: validators,
      semanticRetryExhausted: true,
      rejectionDetailKey: 'runtimeBodyImageSignatureRejected',
    );
  }

  Future<ByteResponse> _runtimeBodyResponse(
    Uri uri,
    ComicResourceBody body, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
    required bool semanticRetryExhausted,
    required String rejectionDetailKey,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) async {
    try {
      _throwIfTaskCancelled(control);
      if (!hasSupportedEncodedImageSignature(body.metadataPrefix)) {
        _invalidate(uri);
        if (semanticRetryExhausted) _failedStreams.add(uri);
        throw Failure(
          code: ErrorCode.source,
          message: 'source runtime returned non-image bytes for $uri',
          details: <String, Object?>{
            'sourceMediaProtocolMismatch': true,
            'sourceMediaSemanticRejected': true,
            if (semanticRetryExhausted) 'sourceSemanticRetryExhausted': true,
            rejectionDetailKey: true,
          },
        );
      }
      final current = Validators(etag: body.validator);
      final canRange = range != null && range.start <= body.byteLength &&
          (validators == null || validators.isEmpty || validators.matches(current));
      final start = canRange ? range.start : 0;
      final requestedEnd = canRange ? range.end : null;
      final end = requestedEnd != null
          ? (requestedEnd + 1).clamp(start, body.byteLength).toInt()
          : body.byteLength;
      return ByteResponse(
        bytes: body.open(start: start, end: end),
        statusCode: canRange ? HttpStatus.partialContent : HttpStatus.ok,
        rangeStart: start,
        totalLength: body.byteLength,
        validators: current,
        rangeSupported: true,
        flowControl: ByteResponseFlowControl.consumerPacing,
        diagnostics: <String, Object?>{
          'sourceRuntimeBodyDelivery': 'sealed-file-v1',
          ...diagnostics,
        },
        onDiscard: body.dispose,
      );
    } on Object {
      await body.dispose();
      rethrow;
    }
  }

  ByteResponse _runtimeBytesResponse(
    Uri uri,
    Uint8List bytes, {
    ByteRange? range,
    Validators? validators,
    required bool semanticRetryExhausted,
    required String rejectionDetailKey,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) {
    if (!hasSupportedEncodedImageSignature(bytes)) {
      _invalidate(uri);
      if (semanticRetryExhausted) {
        _failedStreams.add(uri);
      }
      throw Failure(
        code: ErrorCode.source,
        message: 'source runtime returned non-image bytes for $uri',
        details: <String, Object?>{
          'sourceMediaProtocolMismatch': true,
          'sourceMediaSemanticRejected': true,
          if (semanticRetryExhausted) 'sourceSemanticRetryExhausted': true,
          rejectionDetailKey: true,
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
      diagnostics: diagnostics,
    );
  }

  ByteResponse _withSourceOpenDiagnostics(
    ByteResponse response, {
    required Uri locator,
    TaskControl? control,
    required int requestPlanMicros,
    required bool requestPlanCacheHit,
    required Map<String, Object?> sourcePlanDiagnostics,
    required int hostOpenMicros,
    required String openPath,
    required bool retryUsed,
    required String? verifiedReuseIdentity,
  }) {
    return ByteResponse(
      // Injected transports must report failed bodies just like the built-in
      // HTTP path, so the next provider attempt consumes the source's retry
      // plan rather than reopening the same broken host. Cancellation keeps
      // its request plan and never spends source semantic recovery budget.
      bytes: response.bytes.handleError((Object error, StackTrace stackTrace) {
        if (control?.cancelled != true &&
            (error is! Failure || error.code != ErrorCode.cancelled)) {
          _failedStreams.add(locator);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }),
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
        if (verifiedReuseIdentity != null)
          'sourceVerifiedReuseIdentity': verifiedReuseIdentity,
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

Object _resourceTransportGenerationIdentity(BrowsableComicSource source) {
  final generationSource = source is ComicResourceTransportGenerationSource
      ? source as ComicResourceTransportGenerationSource
      : null;
  return generationSource?.resourceTransportGenerationIdentity ?? source;
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



bool sourceResourceGenerationRefreshEligible(Object error) {
  if (error is! Failure || error.code != ErrorCode.source) return false;
  final details = error.details;
  final semanticRecoveryUnavailable =
      details['sourceMediaSemanticRejected'] == true &&
      details['sourceSemanticRetryExhausted'] == true &&
      details['sourceSemanticRecoveryUnavailable'] == true &&
      details['sourceSemanticAcceptedPlans'] == 0;
  final resourcePlanReplayUnavailable =
      details['sourceResourcePlanReplayEligible'] == true &&
      details['sourceResourcePlanReplayAttempted'] == true &&
      details['sourceResourcePlanReplayUnavailable'] == true;
  return semanticRecoveryUnavailable || resourcePlanReplayUnavailable;
}

bool _isSourceMediaSemanticRejection(Failure error) =>
    error.details['sourceMediaSemanticRejected'] == true;

bool _isSourceResourcePlanReplayEligible(Failure error) =>
    error.details['sourceResourcePlanReplayEligible'] == true;

bool _requiresSourceClientState(Failure error) =>
    error.details['sourceClientStateRequired'] == true;

bool _sameSemanticRequestUri(Uri left, Uri right) {
  String normalized(Uri value) {
    final raw = value.toString();
    return raw.startsWith('//') ? 'https:$raw' : raw;
  }

  return normalized(left) == normalized(right);
}

Failure _sourceMediaSemanticFailure(
  Uri locator, {
  Object? cause,
  int? acceptedPlans,
  int? sameUrlPlans,
  int? changedUrlPlans,
  int? runtimeTransformPlans,
  int? freshResolvePlans,
  bool? recoveryUnavailable,
}) =>
    Failure(
      code: ErrorCode.source,
      message: 'source image recovery returned non-media bytes for $locator',
      cause: cause,
      details: <String, Object?>{
        'sourceMediaProtocolMismatch': true,
        'sourceMediaSemanticRejected': true,
        'sourceSemanticRetryExhausted': true,
        if (acceptedPlans != null)
          'sourceSemanticAcceptedPlans': acceptedPlans,
        if (sameUrlPlans != null) 'sourceSemanticSameUrlPlans': sameUrlPlans,
        if (changedUrlPlans != null)
          'sourceSemanticChangedUrlPlans': changedUrlPlans,
        if (runtimeTransformPlans != null)
          'sourceSemanticRuntimeTransformPlans': runtimeTransformPlans,
        if (freshResolvePlans != null)
          'sourceSemanticFreshResolvePlans': freshResolvePlans,
        if (recoveryUnavailable != null)
          'sourceSemanticRecoveryUnavailable': recoveryUnavailable,
      },
    );


Failure _sourceResourcePlanReplayUnavailableFailure(
  Uri locator, {
  Object? cause,
}) =>
    Failure(
      code: ErrorCode.source,
      message: 'source resource plan replay unavailable for $locator',
      cause: cause,
      details: const <String, Object?>{
        'sourceResourcePlanReplayEligible': true,
        'sourceResourcePlanReplayAttempted': true,
        'sourceResourcePlanReplayUnavailable': true,
      },
    );

Failure _taskCancelledFailure() => const Failure(
      code: ErrorCode.cancelled,
      message: 'source transport request was cancelled by its scheduler owner',
    );

final class _NoSourceRecoveryAvailable implements Exception {
  const _NoSourceRecoveryAvailable();
}

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
      details: const <String, Object?>{
        'sourceMediaProtocolMismatch': true,
        'sourceMediaSemanticRejected': true,
      },
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
