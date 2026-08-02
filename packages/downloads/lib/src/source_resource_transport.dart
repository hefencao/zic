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
  ExternalPluginResourceTransportPool({SourceResourceDirectOpen? directOpen})
      : _directOpen = directOpen;

  final SourceResourceDirectOpen? _directOpen;
  final Map<String, _SourceResourceTransport> _transports =
      <String, _SourceResourceTransport>{};

  TransportResponseLoader loaderFor(
    BrowsableComicSource source,
    Uri locator,
  ) {
    final sourceId = source.sourceId;
    final transport = _transports.putIfAbsent(
      sourceId,
      () => _SourceResourceTransport(source, _directOpen),
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
  _SourceResourceTransport(this._source, this._directOpen) {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.userAgent = 'zic-venera/0.31.0';
    _client.autoUncompress = false;
  }

  static const _requestPlanTtl = Duration(minutes: 10);
  static const _maxRequestPlans = 256;

  BrowsableComicSource _source;
  final SourceResourceDirectOpen? _directOpen;
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
    final directOpen = _directOpen;
    if (directOpen != null) {
      return directOpen(normalized);
    }
    final method = normalized.method;
    final request = await _client.openUrl(method, normalized.uri);
    request.followRedirects = true;
    request.maxRedirects = 8;
    for (final entry in normalized.headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final requestBody = normalized.body;
    if (requestBody != null && requestBody.isNotEmpty) {
      request.add(requestBody);
    }
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await _abortHttpResponse(response);
      throw Failure(
        code: ErrorCode.network,
        message: 'HTTP ${response.statusCode} for ${normalized.uri}',
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
    final responseBody = _HttpResponseBody(
      response,
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
  );
}

final class _RequestPlanEntry {
  const _RequestPlanEntry({required this.request, required this.resolvedAt});

  final ComicResourceRequest request;
  final DateTime resolvedAt;
}

final class _HttpResponseBody {
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
