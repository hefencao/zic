import 'dart:io';

import 'package:domain/domain.dart';

import 'transport.dart';

final class IoTransport implements Transport {
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
  }) {
    return switch (uri.scheme) {
      'http' || 'https' => http.open(
          uri,
          range: range,
          validators: validators,
        ),
      'file' => file.open(
          uri,
          range: range,
          validators: validators,
        ),
      _ => throw Failure(
          code: ErrorCode.source,
          message: 'unsupported URI scheme: ${uri.scheme}',
        ),
    };
  }

  void close({bool force = false}) => http.close(force: force);
}

final class HttpTransport implements Transport {
  HttpTransport({HttpClient? client})
      : _client = client ?? HttpClient(),
        _ownsClient = client == null;

  final HttpClient _client;
  final bool _ownsClient;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw Failure(
        code: ErrorCode.source,
        message: 'unsupported HTTP URI: $uri',
      );
    }
    range?.validate();

    final request = await _client.getUrl(uri);
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

    final response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw Failure(
        code: ErrorCode.network,
        message: 'HTTP ${response.statusCode} for $uri',
      );
    }

    final parsedRange = _parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    if (response.statusCode == HttpStatus.partialContent && parsedRange == null) {
      await response.drain<void>();
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: '206 response is missing a valid Content-Range header',
      );
    }

    final etag = response.headers.value(HttpHeaders.etagHeader);
    final modifiedValue = response.headers.value(HttpHeaders.lastModifiedHeader);
    final modified = modifiedValue == null ? null : HttpDate.parse(modifiedValue);
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
      onDiscard: () => response.drain<void>(),
    );
  }

  void close({bool force = false}) {
    if (_ownsClient) {
      _client.close(force: force);
    }
  }
}

final class FileTransport implements Transport {
  const FileTransport();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
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
    final start = canServeRange ? range!.start : 0;
    final requestedEnd = canServeRange ? range!.end : null;
    final endExclusive = requestedEnd == null
        ? length
        : (requestedEnd + 1 > length ? length : requestedEnd + 1);

    return ByteResponse(
      bytes: file.openRead(start, endExclusive),
      statusCode: canServeRange ? HttpStatus.partialContent : HttpStatus.ok,
      rangeStart: start,
      totalLength: length,
      validators: currentValidators,
      rangeSupported: true,
    );
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
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  if (end < start) {
    return null;
  }
  final totalValue = match.group(3)!;
  return _ContentRange(
    start: start,
    total: totalValue == '*' ? null : int.parse(totalValue),
  );
}
