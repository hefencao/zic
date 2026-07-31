import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('resolved source request streams chunks before the body completes',
      () async {
    final release = Completer<void>();
    final firstChunkSent = Completer<void>();
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      request.response.contentLength = 6;
      request.response.headers.set(HttpHeaders.etagHeader, '"fixture"');
      request.response.add(<int>[1, 2, 3]);
      await request.response.flush();
      if (!firstChunkSent.isCompleted) firstChunkSent.complete();
      if (requests == 1) await release.future;
      request.response.add(<int>[4, 5, 6]);
      await request.response.close();
    });

    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('http://${server.address.host}:${server.port}/page'),
      ),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);
    final locator = Uri.parse('venera-resource:fixture');
    final loader = pool.loaderFor(source, locator);

    final response = await loader();
    expect(response.totalLength, 6);
    expect(response.validators.etag, '"fixture"');
    final iterator = StreamIterator<List<int>>(response.bytes);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[1, 2, 3]);
    await firstChunkSent.future;
    expect(release.isCompleted, isFalse);

    release.complete();
    final rest = <int>[];
    while (await iterator.moveNext()) {
      rest.addAll(iterator.current);
    }
    expect(rest, <int>[4, 5, 6]);
    expect(source.resolveCalls, 1);
    expect(source.loadCalls, 0);

    final second = await loader();
    expect(await _collect(second.bytes), <int>[1, 2, 3, 4, 5, 6]);
    expect(
      source.resolveCalls,
      2,
      reason: 'a later download refreshes potentially expiring request URLs',
    );
  });

  test('a replacement source identity does not close an active transport',
      () async {
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      return server.close(force: true);
    });
    server.listen((request) async {
      request.response.contentLength = 6;
      request.response.add(<int>[1, 2, 3]);
      await request.response.flush();
      await release.future;
      try {
        request.response.add(<int>[4, 5, 6]);
        await request.response.close();
      } on Object {
        // A failing implementation closes the first source transport here.
      }
    });

    final target = Uri.parse(
      'http://${server.address.host}:${server.port}/page',
    );
    final firstSource = _FixtureSource(
      request: ComicResourceRequest(uri: target),
    );
    final replacementSource = _FixtureSource(
      request: ComicResourceRequest(uri: target),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);
    final response = await pool
        .loaderFor(firstSource, Uri.parse('venera-resource:first'))();
    final iterator = StreamIterator<List<int>>(response.bytes);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[1, 2, 3]);

    // Both wrappers intentionally expose the same sourceId. Registering the
    // replacement must not force-close a transport still owned by this Reader.
    pool.loaderFor(replacementSource, Uri.parse('venera-resource:replacement'));
    release.complete();

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[4, 5, 6]);
    expect(await iterator.moveNext(), isFalse);
  });

  test('GET request plans never upload source data', () async {
    var uploadedBytes = -1;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      uploadedBytes = await request.fold<int>(
        0,
        (total, chunk) => total + chunk.length,
      );
      request.response.contentLength = 4;
      request.response.add(<int>[9, 8, 7, 6]);
      await request.response.close();
    });

    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('http://${server.address.host}:${server.port}/page'),
        method: 'GET',
        headers: const <String, String>{
          'Content-Type': 'application/octet-stream',
          'Content-Length': '4096',
        },
        body: Uint8List.fromList(List<int>.filled(4096, 7)),
      ),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:no-upload'))();

    expect(await _collect(response.bytes), <int>[9, 8, 7, 6]);
    expect(uploadedBytes, 0);
    expect(response.totalLength, 4);
  });

  test('discard cancels a streaming response without waiting for completion',
      () async {
    final release = Completer<void>();
    final firstChunk = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      return server.close(force: true);
    });
    server.listen((request) async {
      request.response.contentLength = 1024 * 1024;
      request.response.add(List<int>.filled(4096, 1));
      await request.response.flush();
      if (!firstChunk.isCompleted) firstChunk.complete();
      await release.future;
      try {
        request.response.add(List<int>.filled(1024 * 1024 - 4096, 2));
        await request.response.close();
      } on Object {
        // Expected when the client discards the response.
      }
    });

    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('http://${server.address.host}:${server.port}/slow'),
      ),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);
    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:discard'))();
    final iterator = StreamIterator<List<int>>(response.bytes);
    expect(await iterator.moveNext(), isTrue);
    await firstChunk.future;

    await response.discard().timeout(const Duration(seconds: 1));
    expect(release.isCompleted, isFalse);
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
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:fixture'))();

    expect(await _collect(response.bytes), <int>[7, 8, 9]);
    expect(source.resolveCalls, 1);
    expect(source.loadCalls, 1);
  });

  test('source failure hook replaces only the failed request plan', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/failed') {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.contentLength = 4;
        request.response.add(<int>[4, 3, 2, 1]);
      }
      await request.response.close();
    });
    final origin = 'http://${server.address.host}:${server.port}';
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('$origin/failed')),
      retryRequest: ComicResourceRequest(uri: Uri.parse('$origin/recovered')),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:retry'))();

    expect(await _collect(response.bytes), <int>[4, 3, 2, 1]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 0,
        reason: 'onLoadFailed must not force the complete body through RPC');
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
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
      SourceBrowsePage(items: const <SourceComicSummary>[], offset: offset, hasMore: false);

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();
}
