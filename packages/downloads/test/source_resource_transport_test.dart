import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('resolved source request exposes the first chunk before completion',
      () async {
    final body = _ControlledBody();
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/page')),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened = request;
        return body.response(totalLength: 6, etag: '"fixture"');
      },
    );
    addTearDown(pool.close);
    final loader = pool.loaderFor(
      source,
      Uri.parse('venera-resource:fixture'),
    );

    final response = await loader();
    final iterator = StreamIterator<List<int>>(response.bytes);
    body.add(<int>[1, 2, 3]);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[1, 2, 3]);
    expect(body.closed, isFalse);
    expect(opened?.uri, Uri.parse('https://fixture/page'));
    expect(response.totalLength, 6);
    expect(response.validators.etag, '"fixture"');

    body.add(<int>[4, 5, 6]);
    final closed = body.close();
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[4, 5, 6]);
    expect(await iterator.moveNext(), isFalse);
    await closed;
    expect(source.resolveCalls, 1);
    expect(source.loadCalls, 0);
  });

  test('a replacement source identity does not discard an active response',
      () async {
    final body = _ControlledBody();
    final target = Uri.parse('https://fixture/page');
    final firstSource = _FixtureSource(
      request: ComicResourceRequest(uri: target),
    );
    final replacementSource = _FixtureSource(
      request: ComicResourceRequest(uri: target),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async => body.response(totalLength: 6),
    );
    addTearDown(pool.close);
    final response = await pool
        .loaderFor(firstSource, Uri.parse('venera-resource:first'))();
    final iterator = StreamIterator<List<int>>(response.bytes);
    body.add(<int>[1, 2, 3]);
    expect(await iterator.moveNext(), isTrue);

    pool.loaderFor(
      replacementSource,
      Uri.parse('venera-resource:replacement'),
    );
    expect(body.discarded, isFalse);
    body.add(<int>[4, 5, 6]);
    final closed = body.close();

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[4, 5, 6]);
    expect(await iterator.moveNext(), isFalse);
    await closed;
  });

  test('default UA reaches directOpen when source omits it', () async {
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/page')),
    );
    final pool = ExternalPluginResourceTransportPool(
      defaultUserAgentProvider: () => 'fixture-default-ua',
      directOpen: (request) async {
        opened = request;
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('mihon:resource:default-ua'))();

    expect(await _collect(response.bytes), <int>[1, 2, 3, 4]);
    expect(opened?.headers[HttpHeaders.userAgentHeader], 'fixture-default-ua');
  });

  test('source UA wins over the default UA', () async {
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/page'),
        headers: const <String, String>{'User-Agent': 'source-owned-ua'},
      ),
    );
    final pool = ExternalPluginResourceTransportPool(
      defaultUserAgentProvider: () => 'fixture-default-ua',
      directOpen: (request) async {
        opened = request;
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[4, 3, 2, 1]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('mihon:resource:source-ua'))();

    expect(await _collect(response.bytes), <int>[4, 3, 2, 1]);
    expect(opened?.headers['User-Agent'], 'source-owned-ua');
  });

  test('GET request normalization removes body and entity headers', () async {
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/page'),
        method: 'get',
        headers: const <String, String>{
          'Content-Type': 'application/octet-stream',
          'Content-Length': '4096',
          'Transfer-Encoding': 'chunked',
          'X-Fixture': 'kept',
        },
        body: Uint8List.fromList(List<int>.filled(4096, 7)),
      ),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened = request;
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[9, 8, 7, 6]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:no-upload'))();

    expect(await _collect(response.bytes), <int>[9, 8, 7, 6]);
    expect(opened?.method, 'GET');
    expect(opened?.body, isNull);
    expect(opened?.headers['Content-Type'], isNull);
    expect(opened?.headers['Content-Length'], isNull);
    expect(opened?.headers['Transfer-Encoding'], isNull);
    expect(opened?.headers['X-Fixture'], 'kept');
    expect(opened?.headers[HttpHeaders.acceptEncodingHeader], 'identity');
  });

  test('discard cancels a controlled response without awaiting completion',
      () async {
    final body = _ControlledBody();
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/slow')),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async => body.response(totalLength: 1024 * 1024),
    );
    addTearDown(pool.close);
    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:discard'))();
    final iterator = StreamIterator<List<int>>(response.bytes);
    body.add(List<int>.filled(4096, 1));
    expect(await iterator.moveNext(), isTrue);

    await response.discard();
    expect(body.discarded, isTrue);
    expect(body.closed, isTrue);
    await iterator.cancel();
    await body.done;
  });

  test('failed direct retry falls back to the source-owned byte transform',
      () async {
    final failed = Uri.parse('https://fixture/failed');
    final retried = Uri.parse('https://fixture/retried');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: retried),
      runtimeBytes: Uint8List.fromList(<int>[6, 5, 4, 3]),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => Future<ByteResponse>.error(
        const Failure(
          code: ErrorCode.network,
          message: 'controlled direct failure',
        ),
      ),
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('mihon:resource:fixture'))();

    expect(await _collect(response.bytes), <int>[6, 5, 4, 3]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 1);
  });

  test('runtime body path is reserved for actual response transforms',
      () async {
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('venera-resource:fixture'),
        requiresRuntimeTransform: true,
      ),
      runtimeBytes: Uint8List.fromList(<int>[7, 8, 9]),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => throw StateError('direct transport must not run'),
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:fixture'))();

    expect(await _collect(response.bytes), <int>[7, 8, 9]);
    expect(source.resolveCalls, 1);
    expect(source.loadCalls, 1);
  });

  test('source retry replaces only the failed request plan', () async {
    final failed = Uri.parse('https://fixture/failed');
    final recovered = Uri.parse('https://fixture/recovered');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: recovered),
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        if (request.uri == failed) {
          throw const Failure(
            code: ErrorCode.network,
            message: 'controlled failure',
          );
        }
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[4, 3, 2, 1]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:retry'))();

    expect(await _collect(response.bytes), <int>[4, 3, 2, 1]);
    expect(opened, <Uri>[failed, recovered]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 0);
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
}

final class _ControlledBody {
  final StreamController<List<int>> _controller =
      StreamController<List<int>>(sync: true);
  bool discarded = false;
  bool closed = false;
  Future<void>? _done;

  Future<void> get done => _done ?? Future<void>.value();

  ByteResponse response({required int? totalLength, String? etag}) =>
      ByteResponse(
        bytes: _controller.stream,
        statusCode: HttpStatus.ok,
        rangeStart: 0,
        totalLength: totalLength,
        validators: Validators(etag: etag),
        onDiscard: discard,
      );

  void add(List<int> bytes) {
    if (closed) throw StateError('controlled body is closed');
    _controller.add(bytes);
  }

  Future<void> close() {
    if (!closed) {
      closed = true;
      _done = _controller.close();
    }
    return done;
  }

  Future<void> discard() async {
    discarded = true;
    if (!closed) {
      closed = true;
      _done = _controller.close();
    }
  }
}

final class _FixtureSource
    implements
        BrowsableComicSource,
        ResolvableComicResourceSource,
        RetryableComicResourceSource {
  _FixtureSource({
    required this.request,
    this.retryRequest,
    Uint8List? runtimeBytes,
  }) : runtimeBytes = runtimeBytes ?? Uint8List(0);

  final ComicResourceRequest request;
  final ComicResourceRequest? retryRequest;
  final Uint8List runtimeBytes;
  int resolveCalls = 0;
  int retryCalls = 0;
  int loadCalls = 0;

  @override
  String get sourceId => 'venera:fixture';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Fixture',
        language: 'en',
        website: Uri.parse('https://example.invalid'),
      );

  @override
  Future<ComicResourceRequest> resolveResource(Uri uri) async {
    resolveCalls++;
    return request;
  }

  @override
  Future<ComicResourceRequest?> retryResource(Uri uri) async {
    retryCalls++;
    return retryRequest;
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    loadCalls++;
    return runtimeBytes;
  }

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async =>
      SourceBrowsePage(
        items: const <SourceComicSummary>[],
        offset: offset,
        hasMore: false,
      );

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();
}
