import 'dart:async';
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

final class ExternalPluginResourceTransportPool {
  final Map<BrowsableComicSource, _SourceResourceTransport> _transports =
      Map<BrowsableComicSource, _SourceResourceTransport>.identity();

  TransportResponseLoader loaderFor(
    BrowsableComicSource source,
    Uri locator,
  ) {
    final transport = _transports.putIfAbsent(
      source,
      () => _SourceResourceTransport(source),
    );
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
  _SourceResourceTransport(this.source) {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.userAgent = 'zic-venera/0.31.0';
    _client.autoUncompress = false;
  }

  final BrowsableComicSource source;
  final HttpClient _client = HttpClient();
  final Map<Uri, Future<ComicResourceRequest>> _requestLoads =
      <Uri, Future<ComicResourceRequest>>{};
  final Set<Uri> _failedStreams = <Uri>{};

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
      final retry = await _retry(uri);
      if (retry == null) rethrow;
      if (retry.requiresRuntimeTransform) {
        return _openRuntimeFallback(uri, range: range, validators: validators);
      }
      return _openDirect(
        uri,
        retry,
        range: range,
        validators: validators,
      );
    } on SocketException catch (error) {
      final retry = await _retry(uri);
      if (retry != null) {
        return retry.requiresRuntimeTransform
            ? _openRuntimeFallback(
                uri,
                range: range,
                validators: validators,
              )
            : _openDirect(
                uri,
                retry,
                range: range,
                validators: validators,
              );
      }
      throw Failure(
        code: ErrorCode.network,
        message: 'source resource socket failure for ${request.uri}',
        cause: error,
      );
    } on HttpException catch (error) {
      final retry = await _retry(uri);
      if (retry != null) {
        return retry.requiresRuntimeTransform
            ? _openRuntimeFallback(
                uri,
                range: range,
                validators: validators,
              )
            : _openDirect(
                uri,
                retry,
                range: range,
                validators: validators,
              );
      }
      throw Failure(
        code: ErrorCode.network,
        message: 'source resource HTTP failure for ${request.uri}',
        cause: error,
      );
    }
  }

  Future<ComicResourceRequest?> _retry(Uri locator) async {
    final retryable = source is RetryableComicResourceSource
        ? source as RetryableComicResourceSource
        : null;
    if (retryable == null) return null;
    return retryable.retryResource(locator);
  }

  Future<ComicResourceRequest> _resolve(Uri locator) {
    final active = _requestLoads[locator];
    if (active != null) return active;
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
    load = resolvable.resolveResource(locator).whenComplete(() {
      if (identical(_requestLoads[locator], load)) {
        _requestLoads.remove(locator);
      }
    });
    _requestLoads[locator] = load;
    return load;
  }

  Future<ByteResponse> _openDirect(
    Uri locator,
    ComicResourceRequest spec, {
    ByteRange? range,
    Validators? validators,
  }) async {
    final method = spec.method.trim().toUpperCase();
    final request = await _client.openUrl(method, spec.uri);
    request.followRedirects = true;
    request.maxRedirects = 8;
    for (final entry in spec.headers.entries) {
      final lower = entry.key.toLowerCase();
      if ((method == 'GET' || method == 'HEAD') &&
          (lower == HttpHeaders.contentLengthHeader ||
              lower == HttpHeaders.contentTypeHeader ||
              lower == HttpHeaders.transferEncodingHeader)) {
        continue;
      }
      request.headers.set(entry.key, entry.value);
    }
    if (request.headers.value(HttpHeaders.acceptEncodingHeader) == null) {
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    }
    if (range != null && (method == 'GET' || method == 'HEAD')) {
      request.headers.set(HttpHeaders.rangeHeader, range.toString());
      final ifRange = validators?.etag ??
          (validators?.lastModified == null
              ? null
              : HttpDate.format(validators!.lastModified!.toUtc()));
      if (ifRange != null) {
        request.headers.set(HttpHeaders.ifRangeHeader, ifRange);
      }
    }
    final requestBody = spec.body;
    if (requestBody != null &&
        requestBody.isNotEmpty &&
        method != 'GET' &&
        method != 'HEAD') {
      request.add(requestBody);
    }
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await _abortHttpResponse(response);
      throw Failure(
        code: ErrorCode.network,
        message: 'HTTP ${response.statusCode} for ${spec.uri}',
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
    final bytes = await source.loadResource(uri);
    final current = Validators(etag: '"runtime-${bytes.length}-${_fnv(bytes)}"');
    final canRange = range != null &&
        range.start <= bytes.length &&
        (validators == null || validators.isEmpty || validators.matches(current));
    final start = canRange ? range!.start : 0;
    final end = canRange && range!.end != null
        ? (range.end! + 1).clamp(start, bytes.length).toInt()
        : bytes.length;
    return ByteResponse(
      bytes: Stream<List<int>>.value(Uint8List.sublistView(bytes, start, end)),
      statusCode: canRange ? HttpStatus.partialContent : HttpStatus.ok,
      rangeStart: start,
      totalLength: bytes.length,
      validators: current,
      rangeSupported: true,
    );
  }

  void close() => _client.close(force: true);
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
