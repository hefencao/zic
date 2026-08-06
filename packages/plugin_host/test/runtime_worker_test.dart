import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  group('external runtime worker', () {
    test('round-trips all protocol operations through raw messages', () async {
      final driver = _FixtureDriver();
      final worker = ExternalPluginRuntimeWorker(driver: driver);
      final channel = WorkerBackedExternalPluginRuntimeMessageChannel(worker);
      final connection =
          MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
        handshakeMessage: channel.handshakeMessage,
        channel: channel,
      );
      final session = ExternalPluginRuntimeSession(
        plugin: _plugin(ExternalComicPluginFormat.veneraJavaScript),
        connection: connection,
        limits: const ExternalPluginRuntimeLimits(),
      );
      addTearDown(session.close);

      final source = session.sources.single;
      final browse = await source.browse(query: 'fixture');
      expect(browse.items.single.comicId, 'comic-1');
      final comic = await source.loadComic('comic-1');
      expect(comic.chapters.single.chapterId, 'chapter-1');
      final previewSource = source as ComicPreviewSource;
      expect(
        (await previewSource.loadComicPreview('comic-1')).items,
        isEmpty,
      );
      final commentSource = source as ComicCommentSource;
      expect(
        (await commentSource.loadComicComments('comic-1', page: 1)).items,
        isEmpty,
      );
      final chapter = await source.loadChapter('chapter-1');
      expect(chapter.pages.single.pageId, 'page-1');
      final bytes = await source.loadResource(
        Uri.parse('https://cdn.invalid/page-1.webp'),
      );
      expect(bytes, <int>[82, 73, 70, 70]);
      final request = await (source as ResolvableComicResourceSource)
          .resolveResource(Uri.parse('venera-resource:fixture'));
      expect(request.uri, Uri.parse('https://cdn.invalid/page.webp'));
      expect(
        await (source as RetryableComicResourceSource)
            .retryResource(Uri.parse('venera-resource:fixture')),
        isNull,
      );
      final configurable = source as ConfigurableComicSource;
      await configurable.loadSettings();
      await configurable.updateSetting('mirror', 'auto');
      final accountSource = source as AuthenticatableComicSource;
      final account = await accountSource.loadAccount();
      expect(account.supportsCredentials, isTrue);
      await accountSource.loginWithCredentials('reader', 'secret');
      await accountSource.logout();
      expect(driver.operations, ExternalPluginRuntimeOperation.values);
    });

    test('rejects unknown sources before invoking the ecosystem driver',
        () async {
      final driver = _FixtureDriver();
      final worker = ExternalPluginRuntimeWorker(driver: driver);
      final response = ExternalPluginRuntimeResponse.fromMessage(
        await worker.handle(
          ExternalPluginRuntimeRequest.browse(
            requestId: 'unknown-1',
            externalSourceId: 'missing',
            query: '',
            offset: 0,
            limit: 24,
          ).toMessage(),
        ),
      );

      expect(response.error?.code, 'unknown-source');
      expect(driver.operations, isEmpty);
      await worker.close();
    });

    test('rejects duplicate active request identities', () async {
      final gate = Completer<void>();
      final driver = _FixtureDriver(block: gate.future);
      final worker = ExternalPluginRuntimeWorker(driver: driver);
      final request = ExternalPluginRuntimeRequest.browse(
        requestId: 'duplicate-1',
        externalSourceId: 'fixture',
        query: '',
        offset: 0,
        limit: 24,
      );

      final first = worker.handle(request.toMessage());
      await Future<void>.delayed(Duration.zero);
      final second = ExternalPluginRuntimeResponse.fromMessage(
        await worker.handle(request.toMessage()),
      );
      expect(second.error?.code, 'duplicate-request');

      gate.complete();
      expect(
        ExternalPluginRuntimeResponse.fromMessage(await first).isSuccess,
        isTrue,
      );
      await worker.close();
    });

    test('timeout sends cooperative cancellation and retains the permit',
        () async {
      final driver = _CancellingDriver();
      final worker = ExternalPluginRuntimeWorker(driver: driver);
      final channel = WorkerBackedExternalPluginRuntimeMessageChannel(worker);
      final connection =
          MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
        handshakeMessage: channel.handshakeMessage,
        channel: channel,
      );
      final session = ExternalPluginRuntimeSession(
        plugin: _plugin(ExternalComicPluginFormat.mihonExtension),
        connection: connection,
        limits: const ExternalPluginRuntimeLimits(
          invocationTimeout: Duration(milliseconds: 5),
          maxConcurrentInvocations: 1,
        ),
      );
      addTearDown(session.close);
      final source = session.sources.single;

      await expectLater(source.browse(), throwsA(isA<Failure>()));
      await driver.firstCancelled.future;
      final comic = await source.loadComic('comic-1');

      expect(comic.comic.comicId, 'comic-1');
      expect(driver.maxActive, 1);
      expect(driver.cancelledRequests, <String>['request-1']);
    });

    test('close cancels active requests before waiting for driver exit',
        () async {
      final driver = _CloseAwareDriver();
      final worker = ExternalPluginRuntimeWorker(driver: driver);
      final active = worker.handle(
        ExternalPluginRuntimeRequest.browse(
          requestId: 'active-1',
          externalSourceId: 'fixture',
          query: '',
          offset: 0,
          limit: 24,
        ).toMessage(),
      );
      await driver.started.future;

      final firstClose = worker.close();
      final secondClose = worker.close();
      await Future.wait<void>(<Future<void>>[firstClose, secondClose]);
      final response = ExternalPluginRuntimeResponse.fromMessage(await active);

      expect(response.error?.code, 'cancelled');
      expect(driver.closeCalls, 1);
      expect(worker.activeInvocationCount, 0);
    });
  });

  for (final format in ExternalComicPluginFormat.values) {
    test('${format.name} executor passes the shared worker conformance fixture',
        () async {
      final driver = _FixtureDriver(
        runtimeId: '${format.name}-runtime',
      );
      final plugin = _plugin(format);
      final inspection = _inspection(format);
      final ExternalPluginExecutor executor = switch (format) {
        ExternalComicPluginFormat.mihonExtension => MihonIsolatedExecutor(
            backend: _MihonWorkerBackend(driver),
          ),
        ExternalComicPluginFormat.veneraJavaScript => VeneraSandboxExecutor(
            backend: _VeneraWorkerBackend(driver),
          ),
      };

      final session = await executor.activate(plugin, inspection);
      addTearDown(session.close);
      final source = session.sources.single;
      expect((await source.browse()).items.single.title, 'Fixture Comic');
      expect((await source.loadComic('comic-1')).chapters, hasLength(1));
      expect((await source.loadChapter('chapter-1')).pages, hasLength(1));
      expect(
        await source.loadResource(
          Uri.parse('https://cdn.invalid/page-1.webp'),
        ),
        <int>[82, 73, 70, 70],
      );
    });
  }
}

ExternalComicPluginCatalogEntry _plugin(ExternalComicPluginFormat format) {
  final prefix = switch (format) {
    ExternalComicPluginFormat.mihonExtension => 'mihon',
    ExternalComicPluginFormat.veneraJavaScript => 'venera',
  };
  return ExternalComicPluginCatalogEntry(
    format: format,
    pluginId: '$prefix:fixture-plugin',
    name: 'Fixture Plugin',
    version: '1.0.0',
    entrypoint: Uri.parse('https://repo.invalid/fixture'),
    sources: <ExternalComicPluginSource>[
      ExternalComicPluginSource(
        sourceId: '$prefix:fixture',
        externalId: 'fixture',
        name: 'Fixture',
        language: 'en',
      ),
    ],
  );
}

ExternalPluginInspection _inspection(ExternalComicPluginFormat format) =>
    switch (format) {
      ExternalComicPluginFormat.mihonExtension => ExternalPluginInspection(
          format: format,
          payloadSha256: 'aa',
          payloadPath: '/tmp/fixture.apk',
          payloadByteLength: 1,
          packageName: 'dev.fixture.extension',
          signerSha256: 'bb',
          versionCode: 1,
          extensionLib: '1.6',
          mihonEntryClasses: const <String>['dev.fixture.Extension'],
        ),
      ExternalComicPluginFormat.veneraJavaScript => ExternalPluginInspection(
          format: format,
          payloadSha256: 'aa',
          payloadPath: '/tmp/fixture.js',
          payloadByteLength: 1,
          sourceKey: 'fixture',
        ),
    };

final class _MihonWorkerBackend implements MihonIsolatedRuntimeBackend {
  _MihonWorkerBackend(this.driver);

  final ExternalPluginRuntimeDriver driver;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => true;

  @override
  Future<ExternalPluginRuntimeConnection> activate(
    MihonExecutionRequest request,
  ) async => _workerConnection(driver);
}

final class _VeneraWorkerBackend implements VeneraSandboxRuntimeBackend {
  _VeneraWorkerBackend(this.driver);

  final ExternalPluginRuntimeDriver driver;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => true;

  @override
  Future<ExternalPluginRuntimeConnection> activate(
    VeneraExecutionRequest request,
  ) async => _workerConnection(driver);
}

ExternalPluginRuntimeConnection _workerConnection(
  ExternalPluginRuntimeDriver driver,
) {
  final worker = ExternalPluginRuntimeWorker(driver: driver);
  final channel = WorkerBackedExternalPluginRuntimeMessageChannel(worker);
  return MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
    handshakeMessage: channel.handshakeMessage,
    channel: channel,
  );
}

class _FixtureDriver implements ExternalPluginRuntimeDriver {
  _FixtureDriver({this.runtimeId = 'fixture-runtime', this.block});

  @override
  final String runtimeId;
  final Future<void>? block;
  final List<ExternalPluginRuntimeOperation> operations =
      <ExternalPluginRuntimeOperation>[];

  @override
  List<ExternalPluginRuntimeSourceDescriptor> get sources =>
      <ExternalPluginRuntimeSourceDescriptor>[
        ExternalPluginRuntimeSourceDescriptor(
          externalId: 'fixture',
          name: 'Fixture',
          language: 'en',
          website: Uri.parse('https://example.invalid'),
          supportsComicPreview: true,
          supportsComicComments: true,
        ),
      ];

  @override
  Future<Object> invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  ) async {
    operations.add(request.operation);
    await (block ?? Future<void>.value());
    cancellation.throwIfCancelled();
    return switch (request.operation) {
      ExternalPluginRuntimeOperation.loadBrowseSections => <Object?>[
          <String, Object?>{'sectionId': 'popular', 'label': '热门'},
        ],
        ExternalPluginRuntimeOperation.browse => <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'comicId': 'comic-1',
              'title': 'Fixture Comic',
              'authors': <Object?>['Author'],
              'coverUri': 'https://cdn.invalid/cover.jpg',
              'description': 'Fixture',
              'contentRating': 'safe',
            },
          ],
          'offset': request.arguments['offset'],
          'hasMore': false,
        },
        ExternalPluginRuntimeOperation.loadComic => <String, Object?>{
          'comic': <String, Object?>{
            'comicId': 'comic-1',
            'title': 'Fixture Comic',
            'authors': <Object?>['Author'],
            'readingDirection': 'ltr',
          },
          'chapters': <Object?>[_chapter()],
        },
      ExternalPluginRuntimeOperation.loadComicPreview =>
        const <String, Object?>{
          'items': <Object?>[],
          'nextToken': null,
        },
      ExternalPluginRuntimeOperation.loadComicComments =>
        <String, Object?>{
          'page': request.arguments['page'],
          'comments': const <Object?>[],
          'maxPage': request.arguments['page'],
        },
      ExternalPluginRuntimeOperation.loadChapter => <String, Object?>{
          'comicId': 'comic-1',
          'chapter': _chapter(),
          'readingDirection': 'ltr',
          'pages': <Object?>[
            <String, Object?>{
              'pageId': 'page-1',
              'chapterId': 'chapter-1',
              'index': 0,
              'uri': 'https://cdn.invalid/page-1.webp',
              'byteLength': 4,
              'contentKindHint': 'webp',
              'animatedHint': false,
            },
          ],
        },
      ExternalPluginRuntimeOperation.loadResource =>
        Uint8List.fromList(<int>[82, 73, 70, 70]),
      ExternalPluginRuntimeOperation.resolveResource =>
        const <String, Object?>{
          'url': 'https://cdn.invalid/page.webp',
          'method': 'GET',
          'headers': <String, Object?>{},
          'body': null,
          'requiresRuntimeTransform': false,
        },
      ExternalPluginRuntimeOperation.retryResource =>
        const <String, Object?>{'available': false},
      ExternalPluginRuntimeOperation.loadSourceSettings =>
        const <Object?>[],
      ExternalPluginRuntimeOperation.updateSourceSetting =>
        const <String, Object?>{},
      ExternalPluginRuntimeOperation.loadSourceAccount =>
        const <String, Object?>{
          'loggedIn': false,
          'supportsCredentials': true,
          'cookieFields': <Object?>[],
          'loginWebsite': null,
          'registerWebsite': null,
        },
      ExternalPluginRuntimeOperation.loginSourceAccount =>
        const <String, Object?>{},
      ExternalPluginRuntimeOperation.logoutSourceAccount =>
        const <String, Object?>{},
    };
  }

  Map<String, Object?> _chapter() => <String, Object?>{
        'chapterId': 'chapter-1',
        'comicId': 'comic-1',
        'title': 'Chapter 1',
        'sequence': 0,
        'pageCount': 1,
        'sourceRevision': 'r1',
      };

  @override
  Future<void> close() async {}
}

final class _CancellingDriver extends _FixtureDriver {
  final Completer<void> firstCancelled = Completer<void>();
  final List<String> cancelledRequests = <String>[];
  int active = 0;
  int maxActive = 0;

  @override
  Future<Object> invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  ) async {
    active++;
    if (active > maxActive) {
      maxActive = active;
    }
    try {
      if (request.requestId == 'request-1') {
        await cancellation.whenCancelled;
        cancelledRequests.add(request.requestId);
        if (!firstCancelled.isCompleted) {
          firstCancelled.complete();
        }
        cancellation.throwIfCancelled();
      }
      return super.invoke(request, cancellation);
    } finally {
      active--;
    }
  }
}

final class _CloseAwareDriver extends _FixtureDriver {
  final Completer<void> started = Completer<void>();
  int closeCalls = 0;

  @override
  Future<Object> invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  ) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await cancellation.whenCancelled;
    cancellation.throwIfCancelled();
    throw StateError('unreachable');
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}
