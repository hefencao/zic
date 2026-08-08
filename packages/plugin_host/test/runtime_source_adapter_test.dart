import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('resolves a Mihon manga detail URL without leaking opaque parsing', () {
    final payload = base64Url
        .encode(utf8.encode(jsonEncode(<String, Object?>{
          'kind': 'manga',
          'url': '/album/123',
        })))
        .replaceAll('=', '');

    expect(
      resolveMihonComicWebUri(
        comicId: 'mihon:manga:$payload',
        sourceWebsite: Uri.parse('https://18comic.vip/base/'),
      ),
      Uri.parse('https://18comic.vip/album/123'),
    );
    expect(
      resolveMihonComicWebUri(
        comicId: 'comic-1',
        sourceWebsite: Uri.parse('https://example.invalid'),
      ),
      isNull,
    );
  });

  test('canonicalizes mutable Mihon manga aliases by source URL', () {
    String identity(Map<String, Object?> value) {
      final payload = base64Url
          .encode(utf8.encode(jsonEncode(<String, Object?>{
            'kind': 'manga',
            ...value,
          })))
          .replaceAll('=', '');
      return 'mihon:manga:$payload';
    }

    final first = identity(<String, Object?>{
      'url': '/album/123/',
      'title': '旧标题',
      'description': '',
    });
    final second = identity(<String, Object?>{
      'url': '/album/123',
      'title': '新标题',
      'description': '详情加载后补齐的简介',
      'memo': <String, Object?>{'token': 'runtime-only'},
    });

    expect(
      canonicalMihonComicIdentity(
        comicId: first,
        sourceWebsite: Uri.parse('https://18comic.vip/base/'),
      ),
      canonicalMihonComicIdentity(
        comicId: second,
        sourceWebsite: Uri.parse('https://18comic.vip/base/'),
      ),
    );
  });

  test('maps runtime verification requirement to a typed domain failure',
      () async {
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: _VerificationFailureConnection(),
      limits: const ExternalPluginRuntimeLimits(
        maxResponseBytes: 4096,
        maxConcurrentInvocations: 1,
      ),
    );
    addTearDown(session.close);

    await expectLater(
      session.sources.single.browse(),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.sourceVerificationRequired,
        ),
      ),
    );
  });

  test('maps retryable runtime failure to a typed network failure', () async {
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: _RetryableFailureConnection(),
      limits: const ExternalPluginRuntimeLimits(
        maxResponseBytes: 4096,
        maxConcurrentInvocations: 1,
      ),
    );
    addTearDown(session.close);

    await expectLater(
      session.sources.single.browse(),
      throwsA(
        isA<Failure>()
            .having((failure) => failure.code, 'code', ErrorCode.network)
            .having(
              (failure) => failure.details['runtimeErrorCode'],
              'runtime error code',
              'mihon-operation-failed',
            )
            .having(
              (failure) => failure.details['runtimeRetryable'],
              'runtime retryable',
              isTrue,
            ),
      ),
    );
  });

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
    expect(page.items.single.tags, <String>['Action', 'Drama']);

    final comic = await source.loadComic('comic-1');
    expect(comic.comic.title, 'Comic');
    expect(comic.comic.tags, <String>['Action', 'Drama']);
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
    final request = await (source as ResolvableComicResourceSource)
        .resolveResource(Uri.parse('venera-resource:durable-page'));
    expect(request.uri, Uri.parse('https://cdn.invalid/1.webp'));
    expect(request.requiresRuntimeTransform, isFalse);
    expect(
      await (source as RetryableComicResourceSource)
          .retryResource(Uri.parse('venera-resource:durable-page')),
      isNull,
    );
    expect(
      connection.operations,
      <ExternalPluginRuntimeOperation>[
        ExternalPluginRuntimeOperation.browse,
        ExternalPluginRuntimeOperation.loadComic,
        ExternalPluginRuntimeOperation.loadChapter,
        ExternalPluginRuntimeOperation.loadResource,
        ExternalPluginRuntimeOperation.resolveResource,
        ExternalPluginRuntimeOperation.retryResource,
      ],
    );
  });

  test('runtime adapter exposes detail previews and comment pagination',
      () async {
    final connection = _FixtureConnection(
      supportsComicPreview: true,
      supportsComicComments: true,
    );
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single;

    final manifest = await source.loadComic('comic-1');
    expect(manifest.comic.sourceSubId, 'sub-1');
    expect(manifest.preview?.items.single.uri.toString(),
        'https://cdn.invalid/preview-1.jpg');
    expect(manifest.comments?.items.single.userName, 'reader');

    final preview = await (source as ComicPreviewSource).loadComicPreview(
      'comic-1',
      nextToken: 'next-1',
    );
    expect(preview.items, isEmpty);
    final comments = await (source as ComicCommentSource).loadComicComments(
      'comic-1',
      subId: 'sub-1',
      page: 2,
      replyTo: 'comment-1',
    );
    expect(comments.page, 2);
    expect(comments.maxPage, 2);
    expect(
      connection.operations,
      <ExternalPluginRuntimeOperation>[
        ExternalPluginRuntimeOperation.loadComic,
        ExternalPluginRuntimeOperation.loadComicPreview,
        ExternalPluginRuntimeOperation.loadComicComments,
      ],
    );
  });

  test('Venera version capability reads the current page gnd relation',
      () async {
    final connection = _FixtureConnection(
      resource: Uint8List.fromList(
        utf8.encode(
          '<div id="gnd">'
          '<a href="/g/2/new-token/">New &amp; title</a>, '
          'added 2026-08-01 12:30'
          '</div>',
        ),
      ),
    );
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final currentPayload = base64Url.encode(utf8.encode(
      jsonEncode(<String, Object?>{
        'v': 2,
        'id': 'https://example.invalid/g/1/old-token/',
      }),
    )).replaceAll('=', '');
    final currentId = 'venera:comic:$currentPayload';

    final versionSource = source as ComicVersionSource;
    final versions = await versionSource.findComicVersions(currentId);

    expect(versionSource.supportsComicVersions, isTrue);
    expect(versions, hasLength(1));
    expect(versions.single.sourceId, source.sourceId);
    expect(versions.single.title, 'New & title');
    expect(versions.single.date, '2026-08-01 12:30');
    expect(versions.single.generation, 1);
    expect(
      (source as ComicWebUriSource).resolveComicWebUri(versions.single.comicId),
      Uri.parse('https://example.invalid/g/2/new-token/'),
    );
    expect(
      connection.operations,
      <ExternalPluginRuntimeOperation>[
        ExternalPluginRuntimeOperation.loadResource,
      ],
    );
  });

  test('Mihon search filters preserve typed source-owned state', () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(format: ExternalComicPluginFormat.mihonExtension),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single as FilterableBrowsableComicSource;

    final filters = await source.loadSearchFilters();
    expect(filters, hasLength(1));
    expect(filters.single.kind, SourceSearchFilterKind.checkBox);
    expect(filters.single.filterId, '0');
    expect(filters.single.value, isFalse);

    await source.browseWithFilters(
      sectionId: 'latest',
      filterState: const <String, Object?>{'0': true},
    );
    expect(
      connection.lastRequest?.arguments['filterState'],
      <String, Object?>{'0': true},
    );
  });

  test('Mihon resolves host-streamable request plans and refreshes retry',
      () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(format: ExternalComicPluginFormat.mihonExtension),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final locator = Uri.parse('mihon:resource:fixture');

    final request = await (source as ResolvableComicResourceSource)
        .resolveResource(locator);
    final retry = await (source as RetryableComicResourceSource)
        .retryResource(locator);

    expect(request.uri, Uri.parse('https://cdn.invalid/1.webp'));
    expect(request.method, 'GET');
    expect(request.requiresRuntimeTransform, isFalse);
    expect(retry?.uri, request.uri);
    expect(retry?.requiresRuntimeTransform, isFalse);
    expect(
      connection.operations,
      <ExternalPluginRuntimeOperation>[
        ExternalPluginRuntimeOperation.resolveResource,
        ExternalPluginRuntimeOperation.resolveResource,
      ],
    );
    expect(
      connection.operations,
      isNot(contains(ExternalPluginRuntimeOperation.loadResource)),
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

  test('legacy Venera runtime locator is rejected before invocation', () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);

    expect(
      () => session.sources.single.loadResource(
        Uri.parse('venera-resource://expired-token'),
      ),
      throwsStateError,
    );
    expect(
      connection.operations,
      isNot(contains(ExternalPluginRuntimeOperation.loadResource)),
    );
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

  test('Venera source operations are serialized even when limits allow more',
      () async {
    final firstGate = Completer<void>();
    final connection = _SequencedConnection(firstGate: firstGate.future);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single;

    final first = source.browse();
    final second = source.loadComic('comic-1');
    await Future<void>.delayed(Duration.zero);

    expect(connection.started, 1);
    expect(connection.maxActive, 1);
    firstGate.complete();
    await first;
    await second;
    expect(connection.maxActive, 1);
  });

  test('Mihon runtime keeps configured parallel invocation capacity', () async {
    final firstGate = Completer<void>();
    final connection = _SequencedConnection(firstGate: firstGate.future);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(format: ExternalComicPluginFormat.mihonExtension),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 2),
    );
    addTearDown(session.close);
    final source = session.sources.single;

    final first = source.browse();
    final second = source.loadComic('comic-1');
    await Future<void>.delayed(Duration.zero);

    expect(connection.started, 2);
    expect(connection.maxActive, 2);
    firstGate.complete();
    await first;
    await second;
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

final class _RetryableFailureConnection
    implements ExternalPluginRuntimeConnection {
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
  ) async =>
      ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'mihon-operation-failed',
          message: 'temporary network failure',
          retryable: true,
        ),
      );

  @override
  Future<void> close() async {}
}

final class _VerificationFailureConnection
    implements ExternalPluginRuntimeConnection {
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
  ) async =>
      ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'source-verification-required',
          message: 'Cloudflare verification failed',
          retryable: true,
        ),
      );

  @override
  Future<void> close() async {}
}

final class _FixtureConnection implements ExternalPluginRuntimeConnection {
  _FixtureConnection({
    this.mismatchRequestId = false,
    Uint8List? resource,
    this.block,
    this.closeBlock,
    this.chapterPageCount = 1,
    this.includeChapterPage = true,
    this.supportsComicPreview = false,
    this.supportsComicComments = false,
  }) : resource = resource ?? Uint8List.fromList(<int>[82, 73, 70, 70]);

  final bool mismatchRequestId;
  final Uint8List resource;
  final Future<void>? block;
  final Future<void>? closeBlock;
  final int chapterPageCount;
  final bool includeChapterPage;
  final bool supportsComicPreview;
  final bool supportsComicComments;
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
          supportsComicPreview: supportsComicPreview,
          supportsComicComments: supportsComicComments,
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
        ExternalPluginRuntimeOperation.loadBrowseSections => <Object?>[
          <String, Object?>{'sectionId': 'popular', 'label': '热门'},
        ],
        ExternalPluginRuntimeOperation.loadSearchFilters => <Object?>[
          <String, Object?>{
            'kind': 'checkBox',
            'filterId': '0',
            'label': '已完结',
            'value': false,
          },
        ],
        ExternalPluginRuntimeOperation.browse => <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'comicId': 'comic-1',
                'title': 'Comic',
                'authors': <Object?>['Author'],
                'tags': <Object?>['Action', 'Drama'],
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
              'tags': <Object?>['Action', 'Drama'],
              'coverUri': 'https://cdn.invalid/cover.jpg',
              'description': 'Description',
              'readingDirection': 'topToBottom',
              'subId': 'sub-1',
            },
            'chapters': <Object?>[
              _chapter(),
            ],
            'preview': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'uri': 'https://cdn.invalid/preview-1.jpg',
                  'label': '第 1 页',
                },
              ],
              'nextToken': 'next-1',
            },
            'comments': <String, Object?>{
              'page': 1,
              'comments': <Object?>[
                <String, Object?>{
                  'id': 'comment-1',
                  'userName': 'reader',
                  'avatar': 'https://cdn.invalid/avatar.jpg',
                  'content': 'Nice',
                  'replyCount': 2,
                },
              ],
              'maxPage': 2,
            },
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
        ExternalPluginRuntimeOperation.resolveResource =>
          const <String, Object?>{
            'url': 'https://cdn.invalid/1.webp',
            'method': 'GET',
            'headers': <String, Object?>{},
            'body': null,
            'requiresRuntimeTransform': false,
          },
        ExternalPluginRuntimeOperation.retryResource =>
          const <String, Object?>{'available': false},
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
          ExternalPluginRuntimeOperation.loadBrowseSections => <Object?>[
          <String, Object?>{'sectionId': 'popular', 'label': '热门'},
        ],
        ExternalPluginRuntimeOperation.loadSearchFilters => <Object?>[
          <String, Object?>{
            'kind': 'checkBox',
            'filterId': '0',
            'label': '已完结',
            'value': false,
          },
        ],
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
          ExternalPluginRuntimeOperation.loadChapter =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.loadResource =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.resolveResource =>
            throw UnimplementedError(),
          ExternalPluginRuntimeOperation.retryResource =>
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
