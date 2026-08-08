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

/// Optional host transport capability after request normalization.
///
/// App composition normally leaves this null and uses the shared [HttpClient].
/// Alternative hosts and owner-package tests can provide the same streaming
/// response contract without changing request-plan or DownloadSession logic.
typedef SourceResourceDirectOpen = Future<ByteResponse> Function(
  ComicResourceRequest request,
);

final class ExternalPluginResourceTransportPool {
  ExternalPluginResourceTransportPool({
    SourceResourceDirectOpen? directOpen,
    String Function()? defaultUserAgentProvider,
  })  : _directOpen = directOpen,
        _defaultUserAgentProvider = defaultUserAgentProvider;

  final SourceResourceDirectOpen? _directOpen;
  final String Function()? _defaultUserAgentProvider;
  final Map<String, _SourceResourceTransport> _transports =
      <String, _SourceResourceTransport>{};

  TransportResponseLoader loaderFor(
    BrowsableComicSource source,
    Uri locator,
  ) {
    final sourceId = source.sourceId;
    final transport = _transports.putIfAbsent(
      sourceId,
      () => _SourceResourceTransport(
        source,
        _directOpen,
        _defaultUserAgentProvider,
      ),
    );
    transport.updateSource(source);
    return ({ByteRange? range, Validators? validators}) => transport.open(
          locator,
          range: range,
          validators: validators,
        );
  }

  void close() {
    for (final transport in _transports.values) {
      transport.close();
    }
    _transports.clear();
  }
}

final class _SourceResourceTransport implements Transport {
  _SourceResourceTransport(
    this._source,
    this._directOpen,
    this._defaultUserAgentProvider,
  ) {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.autoUncompress = false;
  }

  static const _requestPlanTtl = Duration(minutes: 10);
  static const _maxRequestPlans = 256;

  BrowsableComicSource _source;
  final SourceResourceDirectOpen? _directOpen;
  final String Function()? _defaultUserAgentProvider;
  final HttpClient _client = HttpClient();
  final Map<Uri, Future<ComicResourceRequest>> _requestLoads =
      <Uri, Future<ComicResourceRequest>>{};
  final LinkedHashMap<Uri, _RequestPlanEntry> _requestPlans =
      LinkedHashMap<Uri, _RequestPlanEntry>();
  final Set<Uri> _failedStreams = <Uri>{};

  void updateSource(BrowsableComicSource source) {
    if (identical(_source, source)) return;
    _source = source;
    // Authentication/settings may have changed with the wrapper. Keep the
    // shared HttpClient and active response streams, but do not reuse plans
    // resolved by the previous runtime instance.
    _requestPlans.clear();
  }

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    range?.validate();
    var request = await _resolve(uri);
    if (_failedStreams.remove(uri)) {
      request = await _retry(uri) ?? request;
    }
    if (request.requiresRuntimeTransform) {
      return _openRuntimeFallback(uri, range: range, validators: validators);
    }
    try {
      return await _openDirect(
        uri,
        request,
        range: range,
        validators: validators,
      );
    } on Failure catch (error) {
      if (error.code != ErrorCode.network) rethrow;
      _invalidate(uri);
      if (error.details['sourceMediaProtocolMismatch'] == true) {
        // The HTTP transaction itself succeeded, but it did not return encoded
        // media. This is the signature of a source-owned OkHttp interceptor,
        // authentication/TLS policy or anti-bot response that cannot be
        // reproduced by the shared Dart HttpClient. Do not issue the same host
        // request twice; execute the existing source-owned compatibility path.
        return _openRuntimeFallback(
          uri,
          range: range,
          validators: validators,
        );
      }
      final retry = await _retry(uri);
      if (retry == null) rethrow;
      return _openRetryPlan(
        uri,
        retry,
        range: range,
        validators: validators,
      );
    } on IOException catch (error) {
      _invalidate(uri);
      final retry = await _retry(uri);
      if (retry != null) {
        return _openRetryPlan(
          uri,
          retry,
          range: range,
          validators: validators,
        );
      }
      throw Failure(
        code: ErrorCode.network,
        message: 'source resource transport failure for ${request.uri}',
        cause: error,
      );
    }
  }

  Future<ComicResourceRequest?> _retry(Uri locator) async {
    final source = _source;
    final retryable = source is RetryableComicResourceSource
        ? source as RetryableComicResourceSource
        : null;
    if (retryable == null) return null;
    final replacement = await retryable.retryResource(locator);
    if (replacement != null) _remember(locator, replacement);
    return replacement;
  }

  Future<ComicResourceRequest> _resolve(Uri locator) {
    final cached = _cached(locator);
    if (cached != null) return Future<ComicResourceRequest>.value(cached);
    final active = _requestLoads[locator];
    if (active != null) return active;
    final source = _source;
    final resolvable = source is ResolvableComicResourceSource
        ? source as ResolvableComicResourceSource
        : null;
    if (resolvable == null) {
      final direct = locator.scheme == 'http' || locator.scheme == 'https';
      return Future<ComicResourceRequest>.value(
        ComicResourceRequest(
          uri: locator,
          requiresRuntimeTransform: !direct,
        ),
      );
    }
    late final Future<ComicResourceRequest> load;
    load = resolvable.resolveResource(locator).then((request) {
      _remember(locator, request);
      return request;
    }).whenComplete(() {
      if (identical(_requestLoads[locator], load)) {
        _requestLoads.remove(locator);
      }
    });
    _requestLoads[locator] = load;
    return load;
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

  Future<ByteResponse> _openRetryPlan(
    Uri locator,
    ComicResourceRequest request, {
    ByteRange? range,
    Validators? validators,
  }) async {
    if (request.requiresRuntimeTransform) {
      return _openRuntimeFallback(
        locator,
        range: range,
        validators: validators,
      );
    }
    try {
      return await _openDirect(
        locator,
        request,
        range: range,
        validators: validators,
      );
    } on Failure catch (error) {
      if (error.code != ErrorCode.network) rethrow;
    } on IOException {
      // A source-owned OkHttp interceptor, cookie jar or TLS stack can make
      // the host request unusable. Preserve complete-body compatibility only
      // after the streaming request plan has actually failed.
    }
    return _openRuntimeFallback(
      locator,
      range: range,
      validators: validators,
    );
  }

  Future<ByteResponse> _openDirect(
    Uri locator,
    ComicResourceRequest spec, {
    ByteRange? range,
    Validators? validators,
  }) async {
    final normalized = normalizeSourceResourceRequest(
      spec,
      range: range,
      validators: validators,
    );
    final effective = _applyDefaultUserAgent(
      normalized,
      _defaultUserAgentProvider,
    );
    final directOpen = _directOpen;
    if (directOpen != null) {
      return directOpen(effective);
    }
    final method = effective.method;
    final request = await _client.openUrl(method, effective.uri);
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
    final response = await request.close();
    if (response.isRedirect || response.cookies.isNotEmpty) {
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
      onDiscard: responseBody.abort,
    );
  }

  Future<ByteResponse> _openRuntimeFallback(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    final bytes = await _source.loadResource(uri);
    final current = Validators(etag: '"runtime-${bytes.length}-${_fnv(bytes)}"');
    final canRange = range != null &&
        range.start <= bytes.length &&
        (validators == null || validators.isEmpty || validators.matches(current));
    final start = canRange ? range!.start : 0;
    final end = canRange && range!.end != null
        ? (range.end! + 1).clamp(start, bytes.length).toInt()
        : bytes.length;
    return ByteResponse(
      bytes: _chunkRuntimeBytes(Uint8List.sublistView(bytes, start, end)),
      statusCode: canRange ? HttpStatus.partialContent : HttpStatus.ok,
      rangeStart: start,
      totalLength: bytes.length,
      validators: current,
      rangeSupported: true,
    );
  }

  void close() {
    _requestLoads.clear();
    _requestPlans.clear();
    _client.close(force: true);
  }
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
}) async {
  final iterator = StreamIterator<List<int>>(response);
  final prefetched = <List<int>>[];
  final prefix = BytesBuilder(copy: false);
  try {
    while (prefix.length < 16 && await iterator.moveNext()) {
      final chunk = iterator.current;
      if (chunk.isEmpty) continue;
      prefetched.add(chunk);
      prefix.add(chunk);
    }
  } on Object {
    onError();
    await iterator.cancel();
    rethrow;
  }
  final bytes = prefix.takeBytes();
  if (!_looksLikeEncodedMediaPrefix(bytes)) {
    await iterator.cancel();
    throw Failure(
      code: ErrorCode.network,
      message: 'source host transport returned non-media bytes for $locator',
      details: const <String, Object?>{'sourceMediaProtocolMismatch': true},
    );
  }
  return _PrefetchedHttpResponseBody(
    iterator,
    prefetched,
    onError: onError,
  );
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
    try {
      for (final chunk in _prefetched) {
        if (_aborted) return;
        yield chunk;
      }
      while (!_aborted && await _iterator.moveNext()) {
        yield _iterator.current;
      }
    } on Object {
      _onError();
      rethrow;
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

bool _looksLikeEncodedMediaPrefix(Uint8List bytes) {
  bool matches(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  if (matches(0, const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) ||
      matches(0, const <int>[0xff, 0xd8, 0xff]) ||
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
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  if (end < start) return null;
  final total = match.group(3)!;
  return _ParsedContentRange(start, total == '*' ? null : int.parse(total));
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
