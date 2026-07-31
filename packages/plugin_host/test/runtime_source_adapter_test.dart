import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('shared runtime adapter exposes one ordinary browsable source', () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(
        maxResponseBytes: 4096,
        maxConcurrentInvocations: 2,
      ),
    );
    addTearDown(session.close);
    final source = session.sources.single;

    expect(source.sourceId, 'venera:fixture');
    expect(source.descriptor.name, 'Fixture');

    final page = await source.browse(query: 'query', offset: 0, limit: 24);
    expect(page.items.single.comicId, 'comic-1');
    expect(page.items.single.sourceId, source.sourceId);

    final comic = await source.loadComic('comic-1');
    expect(comic.comic.title, 'Comic');
    expect(comic.comic.readingDirection, ReadingDirection.vertical);
    expect(comic.chapters.single.chapterId, 'chapter-1');

    final chapter = await source.loadChapter('chapter-1');
    expect(chapter.readingDirection, ReadingDirection.vertical);
    expect(chapter.pages.single.uri.toString(), 'https://cdn.invalid/1.webp');
    expect(chapter.pages.single.contentKindHint, ContentKindHint.webp);
    expect(chapter.chapter.pageCount, 1);

    final bytes = await source.loadResource(
      Uri.parse('https://cdn.invalid/1.webp'),
    );
    expect(bytes, <int>[82, 73, 70, 70]);
    expect(
      connection.operations,
      <ExternalPluginRuntimeOperation>[
        ExternalPluginRuntimeOperation.browse,
        ExternalPluginRuntimeOperation.loadComic,
        ExternalPluginRuntimeOperation.loadChapter,
        ExternalPluginRuntimeOperation.loadResource,
      ],
    );
  });

  test('resolved page list replaces an unknown reported page count', () async {
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: _FixtureConnection(chapterPageCount: 0),
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);

    final chapter = await session.sources.single.loadChapter('chapter-1');

    expect(chapter.chapter.pageCount, chapter.pages.length);
    expect(chapter.chapter.pageCount, 1);
  });

  test('concurrent identical resource loads share one runtime invocation',
      () async {
    final gate = Completer<void>();
    final connection = _FixtureConnection(block: gate.future);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final uri = Uri.parse('venera-resource:durable-page');

    final first = source.loadResource(uri);
    final second = source.loadResource(uri);
    await Future<void>.delayed(Duration.zero);

    expect(
      connection.operations
          .where((value) =>
              value == ExternalPluginRuntimeOperation.loadResource)
          .length,
      1,
    );
    gate.complete();
    expect(await first, <int>[82, 73, 70, 70]);
    expect(await second, <int>[82, 73, 70, 70]);
  });

  test('Mihon source settings round-trip through the runtime adapter', () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(format: ExternalComicPluginFormat.mihonExtension),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single as ConfigurableComicSource;

    final settings = await source.loadSettings();
    final mirror = settings.first;
    expect(mirror.key, 'mirror');
    expect(mirror.kind, ComicSourceSettingKind.select);
    expect(mirror.value, 'auto');
    expect(mirror.choices.single.label, '自动');
    expect(settings.last.kind, ComicSourceSettingKind.action);
    expect(settings.last.value, '刷新');

    await source.updateSetting('mirror', 'https://mirror.invalid');
    expect(connection.lastRequest?.arguments, <String, Object?>{
      'key': 'mirror',
      'value': 'https://mirror.invalid',
    });
  });

  test('adapter rejects a resolved chapter without readable pages', () async {
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: _FixtureConnection(includeChapterPage: false),
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);

    await expectLater(
      session.sources.single.loadChapter('chapter-1'),
      throwsFormatException,
    );
  });

  test('adapter rejects mismatched response identities', () async {
    final connection = _FixtureConnection(mismatchRequestId: true);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);

    await expectLater(
      session.sources.single.browse(),
      throwsA(isA<Failure>()),
    );
  });

  test('adapter enforces response bytes independently of backend claims',
      () async {
    final connection = _FixtureConnection(
      resource: Uint8List(32),
    );
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxResponseBytes: 8),
    );
    addTearDown(session.close);

    await expectLater(
      session.sources.single.loadResource(Uri.parse('https://cdn.invalid/x')),
      throwsA(isA<Failure>()),
    );
  });

  test('timed-out work keeps its concurrency permit until backend exit',
      () async {
    final firstGate = Completer<void>();
    final connection = _SequencedConnection(firstGate: firstGate.future);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(
        invocationTimeout: Duration(milliseconds: 5),
        maxConcurrentInvocations: 1,
      ),
    );
    addTearDown(session.close);
    final source = session.sources.single;

    await expectLater(source.browse(), throwsA(isA<Failure>()));
    final second = source.loadComic('comic-1');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(connection.started, 1);

    firstGate.complete();
    await second;
    expect(connection.maxActive, 1);
  });

  test('concurrent close calls join the same backend shutdown', () async {
    final closeGate = Completer<void>();
    final connection = _FixtureConnection(closeBlock: closeGate.future);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );

    final first = session.close();
    final second = session.close();
    var secondCompleted = false;
    second.then<void>((_) {
      secondCompleted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(secondCompleted, isFalse);

    closeGate.complete();
    await Future.wait<void>(<Future<void>>[first, second]);
    expect(connection.closeCalls, 1);
  });

  test('session close rejects queued work and owns connection teardown',
      () async {
    final gate = Completer<void>();
    final connection = _FixtureConnection(block: gate.future);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(
        maxConcurrentInvocations: 1,
      ),
    );
    final source = session.sources.single;
    final active = source.browse();
    final queued = source.loadComic('comic-1');
    final queuedExpectation = expectLater(queued, throwsStateError);
    final closing = session.close();
    gate.complete();

    await active;
    await queuedExpectation;
    await closing;
    expect(connection.closed, isTrue);
  });
}

ExternalComicPluginCatalogEntry _plugin({
  ExternalComicPluginFormat format =
      ExternalComicPluginFormat.veneraJavaScript,
}) =>
    ExternalComicPluginCatalogEntry(
      format: format,
      pluginId: 'venera:fixture',
      name: 'Fixture',
      version: '1.0.0',
      entrypoint: Uri.parse('https://repo.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(
          sourceId: 'venera:fixture',
          externalId: 'fixture',
          name: 'Fixture',
          language: 'en',
        ),
      ],
    );

final class _FixtureConnection implements ExternalPluginRuntimeConnection {
  _FixtureConnection({
    this.mismatchRequestId = false,
    Uint8List? resource,
    this.block,
    this.closeBlock,
    this.chapterPageCount = 1,
    this.includeChapterPage = true,
  }) : resource = resource ?? Uint8List.fromList(<int>[82, 73, 70, 70]);

  final bool mismatchRequestId;
  final Uint8List resource;
  final Future<void>? block;
  final Future<void>? closeBlock;
  final int chapterPageCount;
  final bool includeChapterPage;
  final List<ExternalPluginRuntimeOperation> operations =
      <ExternalPluginRuntimeOperation>[];
  bool closed = false;
  int closeCalls = 0;
  ExternalPluginRuntimeRequest? lastRequest;

  @override
  List<ExternalPluginRuntimeSourceDescriptor> get sources =>
      <ExternalPluginRuntimeSourceDescriptor>[
        ExternalPluginRuntimeSourceDescriptor(
          externalId: 'fixture',
          name: 'Fixture',
          language: 'en',
          website: Uri.parse('https://example.invalid'),
        ),
      ];

  @override
  Future<ExternalPluginRuntimeResponse> invoke(
    ExternalPluginRuntimeRequest request,
  ) async {
    lastRequest = request;
    operations.add(request.operation);
    await (block ?? Future<void>.value());
    final requestId = mismatchRequestId ? 'other' : request.requestId;
    return ExternalPluginRuntimeResponse.success(
      requestId: requestId,
      payload: switch (request.operation) {
        ExternalPluginRuntimeOperation.browse => <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'comicId': 'comic-1',
                'title': 'Comic',
                'authors': <Object?>['Author'],
                'coverUri': 'https://cdn.invalid/cover.jpg',
                'description': 'Description',
                'contentRating': 'safe',
              },
            ],
            'offset': 0,
            'hasMore': false,
          },
        ExternalPluginRuntimeOperation.loadComic => <String, Object?>{
            'comic': <String, Object?>{
              'comicId': 'comic-1',
              'title': 'Comic',
              'authors': <Object?>['Author'],
              'coverUri': 'https://cdn.invalid/cover.jpg',
              'description': 'Description',
              'readingDirection': 'topToBottom',
            },
            'chapters': <Object?>[
              _chapter(),
            ],
          },
        ExternalPluginRuntimeOperation.loadChapter => <String, Object?>{
            'comicId': 'comic-1',
            'chapter': _chapter(),
            'readingDirection': 'topToBottom',
            'pages': includeChapterPage
                ? <Object?>[
                    <String, Object?>{
                      'pageId': 'page-1',
                      'chapterId': 'chapter-1',
                      'index': 0,
                      'uri': 'https://cdn.invalid/1.webp',
                      'width': 100,
                      'height': 200,
                      'byteLength': 4,
                      'contentKindHint': 'webp',
                      'animatedHint': true,
                      'checksum': 'aa',
                    },
                  ]
                : <Object?>[],
          },
        ExternalPluginRuntimeOperation.loadResource => resource,
        ExternalPluginRuntimeOperation.loadSourceSettings =>
          const <Object?>[
            <String, Object?>{
              'key': 'mirror',
              'title': '镜像',
              'summary': '选择镜像',
              'kind': 'select',
              'value': 'auto',
              'sensitive': false,
              'choices': <Object?>[
                <String, Object?>{'value': 'auto', 'label': '自动'},
              ],
            },
            <String, Object?>{
              'key': 'refresh',
              'title': '刷新域名',
              'summary': null,
              'kind': 'action',
              'value': '刷新',
              'sensitive': false,
              'choices': <Object?>[],
            },
          ],
        ExternalPluginRuntimeOperation.updateSourceSetting =>
          const <String, Object?>{},
        ExternalPluginRuntimeOperation.loadSourceAccount =>
          const <String, Object?>{
            'loggedIn': false,
            'supportsCredentials': true,
            'cookieFields': <Object?>['igneous'],
            'loginWebsite': 'https://example.invalid/login',
            'registerWebsite': null,
          },
        ExternalPluginRuntimeOperation.loginSourceAccount =>
          const <String, Object?>{},
        ExternalPluginRuntimeOperation.logoutSourceAccount =>
          const <String, Object?>{},
      },
    );
  }

  Map<String, Object?> _chapter() => <String, Object?>{
        'chapterId': 'chapter-1',
        'comicId': 'comic-1',
        'title': 'Chapter 1',
        'sequence': 0,
        'pageCount': chapterPageCount,
        'sourceRevision': 'r1',
      };

  @override
  Future<void> close() async {
    closeCalls++;
    await (closeBlock ?? Future<void>.value());
    closed = true;
  }
}

final class _SequencedConnection implements ExternalPluginRuntimeConnection {
  _SequencedConnection({required this.firstGate});

  final Future<void> firstGate;
  int started = 0;
  int active = 0;
  int maxActive = 0;
  bool closed = false;

  @override
  List<ExternalPluginRuntimeSourceDescriptor> get sources =>
      <ExternalPluginRuntimeSourceDescriptor>[
        ExternalPluginRuntimeSourceDescriptor(
          externalId: 'fixture',
          name: 'Fixture',
          language: 'en',
          website: Uri.parse('https://example.invalid'),
        ),
      ];

  @override
  Future<ExternalPluginRuntimeResponse> invoke(
    ExternalPluginRuntimeRequest request,
  ) async {
    started++;
    active++;
    if (active > maxActive) {
      maxActive = active;
    }
    try {
      if (started == 1) {
        await firstGate;
      }
      return ExternalPluginRuntimeResponse.success(
        requestId: request.requestId,
        payload: switch (request.operation) {
          ExternalPluginRuntimeOperation.browse => <String, Object?>{
              'items': <Object?>[],
              'offset': request.arguments['offset'],
              'hasMore': false,
            },
          ExternalPluginRuntimeOperation.loadComic => <String, Object?>{
              'comic': <String, Object?>{
                'comicId': 'comic-1',
                'title': 'Comic',
                'authors': <Object?>[],
                'readingDirection': 'ltr',
              },
              'chapters': <Object?>[],
            },
          ExternalPluginRuntimeOperation.loadChapter =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.loadResource =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.loadSourceSettings =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.updateSourceSetting =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.loadSourceAccount =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.loginSourceAccount =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.logoutSourceAccount =>
            throw UnimplementedError(),
        },
      );
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
