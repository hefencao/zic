import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';

import 'transport.dart';

final class IoTransport implements ControlledTransport {
  IoTransport({HttpTransport? http, FileTransport? file})
      : http = http ?? HttpTransport(),
        file = file ?? const FileTransport();

  final HttpTransport http;
  final FileTransport file;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) {
    control?.throwIfCancelled();
    return switch (uri.scheme) {
      'http' || 'https' => http.openControlled(
          uri,
          range: range,
          validators: validators,
          control: control,
        ),
      'file' => file.openControlled(
          uri,
          range: range,
          validators: validators,
          control: control,
        ),
      _ => throw Failure(
          code: ErrorCode.source,
          message: 'unsupported URI scheme: ${uri.scheme}',
        ),
    };
  }

  void close({bool force = false}) => http.close(force: force);
}

final class HttpTransport implements ControlledTransport {
  HttpTransport({
    HttpClient? client,
    Duration connectionTimeout = const Duration(seconds: 15),
    String? userAgent,
    String Function()? userAgentProvider,
  })  : _client = client ?? HttpClient(),
        _ownsClient = client == null,
        _fixedUserAgent = userAgent?.trim(),
        _userAgentProvider = userAgentProvider {
    if (_ownsClient) {
      _client.connectionTimeout = connectionTimeout;
    }
  }

  final HttpClient _client;
  final bool _ownsClient;
  final String? _fixedUserAgent;
  final String Function()? _userAgentProvider;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    try {
      control?.throwIfCancelled();
      return await _open(
        uri,
        range: range,
        validators: validators,
        control: control,
      );
    } on Failure {
      rethrow;
    } on SocketException catch (error) {
      if (control?.cancelled == true) control!.throwIfCancelled();
      final osError = error.osError;
      final osDetails = osError == null
          ? ''
          : ' (${osError.message}, errno ${osError.errorCode})';
      throw Failure(
        code: ErrorCode.network,
        message: 'socket failure for $uri: ${error.message}$osDetails',
        cause: error,
      );
    } on HttpException catch (error) {
      if (control?.cancelled == true) control!.throwIfCancelled();
      throw Failure(
        code: ErrorCode.network,
        message: 'HTTP transport failure for $uri: ${error.message}',
        cause: error,
      );
    }
  }

  Future<ByteResponse> _open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw Failure(
        code: ErrorCode.source,
        message: 'unsupported HTTP URI: $uri',
      );
    }
    range?.validate();

    final request = await _client.getUrl(uri);
    control?.throwIfCancelled();
    final cancellation = control?.whenCancelled.then<void>((_) {
      request.abort();
    });
    final userAgent = _nonEmpty(_fixedUserAgent) ?? _nonEmpty(_userAgentProvider?.call());
    if (userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range.toString());
      final ifRange = validators?.etag ??
          (validators?.lastModified == null
              ? null
              : HttpDate.format(validators!.lastModified!.toUtc()));
      if (ifRange != null) {
        request.headers.set(HttpHeaders.ifRangeHeader, ifRange);
      }
    }

    late final HttpClientResponse response;
    try {
      response = await request.close();
    } finally {
      // The cancellation subscription is intentionally detached after the
      // request has been closed; it is only a request-open abort hook.
      unawaited(cancellation);
    }
    if (control?.cancelled == true) {
      await _drainHttpResponse(response, control: control);
      control!.throwIfCancelled();
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await _drainHttpResponse(response, control: control);
      throw Failure(
        code: ErrorCode.network,
        message: 'HTTP ${response.statusCode} for $uri',
      );
    }

    final parsedRange = _parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    if (response.statusCode == HttpStatus.partialContent && parsedRange == null) {
      await _drainHttpResponse(response, control: control);
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: '206 response is missing a valid Content-Range header',
      );
    }

    final etag = response.headers.value(HttpHeaders.etagHeader);
    final modifiedValue = response.headers.value(HttpHeaders.lastModifiedHeader);
    // Ignore a malformed optional validator rather than returning a live
    // response whose body was never handed to a caller or drained.
    final modified = _tryParseHttpDate(modifiedValue);
    final totalLength = parsedRange?.total ??
        (response.contentLength >= 0 ? response.contentLength : null);
    final acceptsRanges =
        response.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes';

    return ByteResponse(
      bytes: response,
      statusCode: response.statusCode,
      rangeStart: parsedRange?.start ?? 0,
      totalLength: totalLength,
      validators: Validators(etag: etag, lastModified: modified),
      rangeSupported:
          acceptsRanges || response.statusCode == HttpStatus.partialContent,
      flowControl: ByteResponseFlowControl.streamBackpressure,
      onDiscard: () async {
        await _drainHttpResponse(response);
      },
      onDiscardControlled: ({TaskControl? control}) async {
        if (control?.cancelled == true) {
          request.abort();
        }
        await _drainHttpResponse(response, control: control);
      },
    );
  }

  void close({bool force = false}) {
    if (_ownsClient) {
      _client.close(force: force);
    }
  }
}

final class FileTransport implements ControlledTransport {
  const FileTransport();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    if (uri.scheme != 'file') {
      throw Failure(
        code: ErrorCode.source,
        message: 'unsupported file URI: $uri',
      );
    }
    range?.validate();
    final file = File.fromUri(uri);
    if (!await file.exists()) {
      throw Failure(
        code: ErrorCode.source,
        message: 'file does not exist: ${file.path}',
      );
    }

    final length = await file.length();
    final modified = await file.lastModified();
    final currentValidators = Validators(
      etag: '"$length-${modified.microsecondsSinceEpoch}"',
      lastModified: modified.toUtc(),
    );
    final canServeRange = range != null &&
        range.start <= length &&
        (validators == null || validators.isEmpty || validators.matches(currentValidators));
    final start = canServeRange ? range.start : 0;
    final requestedEnd = canServeRange ? range.end : null;
    final endExclusive = requestedEnd == null
        ? length
        : (requestedEnd + 1 > length ? length : requestedEnd + 1);

    control?.throwIfCancelled();
    return ByteResponse(
      bytes: _readFileChunks(
        file,
        start,
        endExclusive,
        control: control,
      ),
      statusCode: canServeRange ? HttpStatus.partialContent : HttpStatus.ok,
      rangeStart: start,
      totalLength: length,
      validators: currentValidators,
      rangeSupported: true,
      disposition: ByteResponseDisposition.durableImmutable,
    );
  }
}

Stream<List<int>> _readFileChunks(
  File file,
  int start,
  int endExclusive, {
  TaskControl? control,
}) async* {
  final reader = await file.open();
  try {
    await reader.setPosition(start);
    var remaining = endExclusive - start;
    while (remaining > 0) {
      control?.throwIfCancelled();
      final chunk = await reader.read(
        remaining < defaultTransportChunkBytes
            ? remaining
            : defaultTransportChunkBytes,
      );
      if (chunk.isEmpty) {
        break;
      }
      remaining -= chunk.length;
      yield chunk;
    }
  } finally {
    await reader.close();
  }
}

final class _ContentRange {
  const _ContentRange({required this.start, required this.total});

  final int start;
  final int? total;
}

_ContentRange? _parseContentRange(String? value) {
  if (value == null) {
    return null;
  }
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
  if (match == null) {
    return null;
  }
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
  if (end < start || (total != null && total <= end)) {
    return null;
  }
  return _ContentRange(start: start, total: total);
}

Future<void> _drainHttpResponse(
  HttpClientResponse response, {
  TaskControl? control,
}) async {
  final iterator = StreamIterator<List<int>>(response);
  try {
    while (await iterator.moveNext()) {
      control?.throwIfCancelled();
    }
  } finally {
    await iterator.cancel();
  }
}

DateTime? _tryParseHttpDate(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    return HttpDate.parse(value);
  } on FormatException {
    return null;
  }
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
