import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:downloads/downloads.dart';
import 'package:rhttp/rhttp.dart' as rhttp;


Future<void>? _rhttpInitialization;
const bool _rhttpReceiveProgressDiagnosticsRequested =
    bool.fromEnvironment('ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS');
const bool _rhttpReceiveProgressDiagnosticsEnabled =
    !bool.fromEnvironment('dart.vm.product') ||
    _rhttpReceiveProgressDiagnosticsRequested;

/// Prewarms the Rust HTTP runtime without blocking the first application frame.
Future<void> prewarmPlatformSourceResourceTransport() =>
    _rhttpInitialization ??= rhttp.Rhttp.init();

/// Production external-source media transport.
///
/// Request-plan resolution, scheduling, retries and artifacts remain owned by
/// `downloads`. This adapter only executes one already-normalized HTTP request
/// through a reusable Rust/reqwest client.
final class RhttpSourceResourceDirectTransport
    implements SourceResourceDirectTransport {
  Future<rhttp.RhttpClient>? _clientFuture;
  bool _closed = false;

  Future<rhttp.RhttpClient> _client() {
    if (_closed) {
      throw StateError('rhttp source resource transport is closed');
    }
    return _clientFuture ??= _createClient();
  }

  Future<rhttp.RhttpClient> _createClient() async {
    await prewarmPlatformSourceResourceTransport();
    if (_closed) {
      throw StateError('rhttp source resource transport is closed');
    }
    return rhttp.RhttpClient.create(
      settings: const rhttp.ClientSettings(
        redirectSettings: rhttp.RedirectSettings.none(),
        timeoutSettings: rhttp.TimeoutSettings(
          connectTimeout: Duration(seconds: 15),
          keepAliveTimeout: Duration(seconds: 60),
          keepAlivePing: Duration(seconds: 30),
        ),
        throwOnStatusCode: false,
      ),
    );
  }

  @override
  Future<ByteResponse> open(
    ComicResourceRequest request, {
    TaskControl? control,
  }) async {
    _throwIfCancelled(control);
    final client = await _client();
    _throwIfCancelled(control);
    final cancelToken = rhttp.CancelToken();
    final taskControl = control;
    if (taskControl != null) {
      unawaited(taskControl.whenCancelled.then((_) => cancelToken.cancel()));
    }
    final body = request.body;
    final receiveProgressDiagnosticsEnabled =
        _rhttpReceiveProgressDiagnosticsEnabled;
    final readDiagnostics = receiveProgressDiagnosticsEnabled
        ? _RhttpReadDiagnostics()
        : null;
    late final rhttp.HttpStreamResponse response;
    try {
      response = await client.requestStream(
        method: rhttp.HttpMethod(request.method),
        url: request.uri.toString(),
        headers: rhttp.HttpHeaders.rawMap(request.headers),
        body: body == null || body.isEmpty
            ? null
            : rhttp.HttpBody.bytes(Uint8List.fromList(body)),
        cancelToken: cancelToken,
        onReceiveProgress: readDiagnostics?.recordReceiveProgress,
      );
    } on rhttp.RhttpCancelException catch (error) {
      throw Failure(
        code: ErrorCode.cancelled,
        message: 'source media request cancelled',
        cause: error,
      );
    } on rhttp.RhttpException catch (error) {
      throw Failure(
        code: ErrorCode.network,
        message: 'source media request failed for ${request.uri}',
        cause: error,
      );
    }
    _throwIfCancelled(control);

    final headers = response.headerMapList;
    if (_headerValues(headers, HttpHeaders.setCookieHeader).isNotEmpty ||
        _isRedirectStatus(response.statusCode)) {
      cancelToken.cancel();
      throw Failure(
        code: ErrorCode.network,
        message:
            'source host replay requires source-owned session state for ${request.uri}',
        details: const <String, Object?>{
          'sourceMediaProtocolMismatch': true,
          'sourceClientStateRequired': true,
        },
      );
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      cancelToken.cancel();
      throw Failure(
        code: ErrorCode.network,
        message: 'HTTP ${response.statusCode} for ${request.uri}',
      );
    }

    final parsedRange = _parseContentRange(
      _headerValue(headers, HttpHeaders.contentRangeHeader),
    );
    if (response.statusCode == HttpStatus.partialContent && parsedRange == null) {
      cancelToken.cancel();
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: '206 response is missing a valid Content-Range header',
      );
    }
    final responseBody = await _prefetchEncodedMediaBody(
      response.body,
      request.uri,
      cancelToken,
      control,
      readDiagnostics,
      validatePrefix: parsedRange == null || parsedRange.start == 0,
    );
    final contentLength = int.tryParse(
      _headerValue(headers, HttpHeaders.contentLengthHeader) ?? '',
    );
    final modified = _headerValue(headers, HttpHeaders.lastModifiedHeader);
    return ByteResponse(
      bytes: responseBody.stream,
      statusCode: response.statusCode,
      rangeStart: parsedRange?.start ?? 0,
      totalLength: parsedRange?.total ?? contentLength,
      validators: Validators(
        etag: _headerValue(headers, HttpHeaders.etagHeader),
        lastModified: _tryParseHttpDate(modified),
      ),
      rangeSupported: response.statusCode == HttpStatus.partialContent ||
          _headerValue(headers, HttpHeaders.acceptRangesHeader)
                  ?.toLowerCase()
                  .contains('bytes') ==
              true,
      diagnostics: <String, Object?>{
        'sourceHostHttpVersion': _httpVersionName(response.version),
        if (response.remoteIp != null && response.remoteIp!.isNotEmpty)
          'sourceHostRemoteIpHash': _stableDiagnosticHash(response.remoteIp!),
        'sourceRhttpReceiveProgressEnabled':
            receiveProgressDiagnosticsEnabled,
      },
      readDiagnostics: readDiagnostics,
      onDiscard: responseBody.abort,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final clientFuture = _clientFuture;
    _clientFuture = null;
    if (clientFuture != null) {
      unawaited(clientFuture.then((client) {
        client.dispose();
      }));
    }
  }
}

final class _RhttpResponseBody {
  _RhttpResponseBody(this.stream, this.abort);

  final Stream<List<int>> stream;
  final Future<void> Function() abort;
}

Future<_RhttpResponseBody> _prefetchEncodedMediaBody(
  Stream<Uint8List> source,
  Uri locator,
  rhttp.CancelToken cancelToken,
  TaskControl? control,
  _RhttpReadDiagnostics? readDiagnostics, {
  bool validatePrefix = true,
}) async {
  final iterator = StreamIterator<Uint8List>(source);
  final prefetched = <Uint8List>[];
  if (validatePrefix) {
    final prefix = BytesBuilder(copy: false);
    try {
      while (prefix.length < 16 && await iterator.moveNext()) {
        _throwIfCancelled(control);
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        readDiagnostics?.recordBodyChunk(chunk.lengthInBytes);
        prefetched.add(chunk);
        prefix.add(chunk);
      }
      _throwIfCancelled(control);
    } on Object {
      cancelToken.cancel();
      await iterator.cancel();
      rethrow;
    }
    if (!_looksLikeEncodedMediaPrefix(prefix.takeBytes())) {
      cancelToken.cancel();
      await iterator.cancel();
      throw Failure(
        code: ErrorCode.network,
        message: 'source host transport returned non-media bytes for $locator',
        details: const <String, Object?>{'sourceMediaProtocolMismatch': true},
      );
    }
  }

  var aborted = false;
  Future<void> abort() async {
    if (aborted) return;
    aborted = true;
    cancelToken.cancel();
    await iterator.cancel();
  }

  final taskControl = control;
  if (taskControl != null) {
    unawaited(taskControl.whenCancelled.then((_) => abort()));
  }
  Stream<List<int>> body() async* {
    var completed = false;
    try {
      // Preserve rhttp's streaming cadence here. DownloadJob is the single
      // framing owner for Reader/page-body ingress (16 KiB startup, then the
      // shared source-progress quantum). A second 64/256 KiB buffer here
      // delays source growth and first-frame decode without reducing any work
      // that DownloadJob would not already coalesce.
      for (final chunk in prefetched) {
        if (aborted) return;
        if (chunk.isNotEmpty) yield chunk;
      }
      while (!aborted && await iterator.moveNext()) {
        if (aborted) return;
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        readDiagnostics?.recordBodyChunk(chunk.lengthInBytes);
        yield chunk;
      }
      completed = true;
    } finally {
      if (!completed) await abort();
    }
  }

  return _RhttpResponseBody(body(), abort);
}

final class _RhttpReadDiagnostics implements ByteResponseReadDiagnostics {
  _RhttpReadDiagnostics() : _clock = Stopwatch()..start();

  final Stopwatch _clock;
  var _progressEvents = 0;
  var _progressBytes = 0;
  var _progressTotalBytes = -1;
  var _progressFirstMicros = 0;
  var _progressLastMicros = 0;
  var _progressMaxGapMicros = 0;
  var _progressMaxDeltaBytes = 0;
  var _bodyEvents = 0;
  var _bodyBytes = 0;
  var _bodyFirstMicros = 0;
  var _bodyLastMicros = 0;
  var _bodyMaxGapMicros = 0;
  var _bodyMinChunkBytes = 0;
  var _bodyMaxChunkBytes = 0;
  var _progressLeadBytesMax = 0;

  void recordReceiveProgress(int count, int total) {
    final now = _clock.elapsedMicroseconds;
    final previousBytes = _progressBytes;
    if (_progressEvents == 0) {
      _progressFirstMicros = now;
    } else {
      final gap = now - _progressLastMicros;
      if (gap > _progressMaxGapMicros) _progressMaxGapMicros = gap;
    }
    final delta = count - previousBytes;
    if (delta > _progressMaxDeltaBytes) _progressMaxDeltaBytes = delta;
    _progressEvents++;
    _progressBytes = count;
    _progressTotalBytes = total;
    _progressLastMicros = now;
    _recordProgressLead();
  }

  void recordBodyChunk(int bytes) {
    final now = _clock.elapsedMicroseconds;
    if (_bodyEvents == 0) {
      _bodyFirstMicros = now;
      _bodyMinChunkBytes = bytes;
    } else {
      final gap = now - _bodyLastMicros;
      if (gap > _bodyMaxGapMicros) _bodyMaxGapMicros = gap;
      if (bytes < _bodyMinChunkBytes) _bodyMinChunkBytes = bytes;
    }
    if (bytes > _bodyMaxChunkBytes) _bodyMaxChunkBytes = bytes;
    _bodyEvents++;
    _bodyBytes += bytes;
    _bodyLastMicros = now;
    _recordProgressLead();
  }

  void _recordProgressLead() {
    final lead = _progressBytes - _bodyBytes;
    if (lead > _progressLeadBytesMax) _progressLeadBytesMax = lead;
  }

  @override
  Map<String, Object?> snapshot() => <String, Object?>{
        'sourceRhttpProgressEvents': _progressEvents,
        'sourceRhttpProgressBytes': _progressBytes,
        'sourceRhttpProgressTotalBytes': _progressTotalBytes,
        'sourceRhttpProgressFirstMicros': _progressFirstMicros,
        'sourceRhttpProgressMaxGapMicros': _progressMaxGapMicros,
        'sourceRhttpProgressMaxDeltaBytes': _progressMaxDeltaBytes,
        'sourceRhttpBodyEvents': _bodyEvents,
        'sourceRhttpBodyBytes': _bodyBytes,
        'sourceRhttpBodyFirstMicros': _bodyFirstMicros,
        'sourceRhttpBodyMaxGapMicros': _bodyMaxGapMicros,
        'sourceRhttpBodyMinChunkBytes': _bodyMinChunkBytes,
        'sourceRhttpBodyMaxChunkBytes': _bodyMaxChunkBytes,
        'sourceRhttpProgressLeadBytesMax': _progressLeadBytesMax,
        'sourceRhttpProgressLeadBytesFinal':
            (_progressBytes - _bodyBytes).clamp(0, 1 << 62).toInt(),
      };
}

String _httpVersionName(rhttp.HttpVersion version) {
  final value = version.toString();
  final dot = value.lastIndexOf('.');
  return dot < 0 ? value : value.substring(dot + 1);
}

String _stableDiagnosticHash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

void _throwIfCancelled(TaskControl? control) {
  if (control?.cancelled != true) return;
  throw const Failure(
    code: ErrorCode.cancelled,
    message: 'source media request cancelled by scheduler owner',
  );
}

List<String> _headerValues(
  Map<String, List<String>> headers,
  String name,
) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return const <String>[];
}

String? _headerValue(Map<String, List<String>> headers, String name) {
  final values = _headerValues(headers, name);
  return values.isEmpty ? null : values.join(', ');
}

bool _isRedirectStatus(int statusCode) =>
    statusCode == HttpStatus.movedPermanently ||
    statusCode == HttpStatus.found ||
    statusCode == HttpStatus.seeOther ||
    statusCode == HttpStatus.temporaryRedirect ||
    statusCode == HttpStatus.permanentRedirect;

DateTime? _tryParseHttpDate(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    return HttpDate.parse(value);
  } on FormatException {
    return null;
  }
}

({int start, int? end, int? total})? _parseContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$', caseSensitive: false)
      .firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final totalValue = match.group(3)!;
  final total = totalValue == '*' ? null : int.tryParse(totalValue);
  if (start == null || end == null || start < 0 || end < start) return null;
  if (total != null && total <= end) return null;
  return (start: start, end: end, total: total);
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
    return brand == 'avif' ||
        brand == 'avis' ||
        brand == 'heic' ||
        brand == 'heix';
  }
  return false;
}
