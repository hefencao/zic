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

  test('maps worker cancellation to typed cancellation failure', () async {
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: _CancelledFailureConnection(),
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
            .having((failure) => failure.code, 'code', ErrorCode.cancelled)
            .having(
              (failure) => failure.details['runtimeErrorCode'],
              'runtime error code',
              'cancelled',
            ),
      ),
    );
  });

  test('Venera source read replay is bounded and forces fresh runtime network',
      () async {
    final connection = _ReplayableSourceReadConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(
        maxResponseBytes: 4096,
        maxConcurrentInvocations: 1,
      ),
    );
    addTearDown(session.close);

    final chapter = await session.sources.single.loadChapter('chapter-1');

    expect(chapter.pages, hasLength(1));
    expect(connection.requests, hasLength(2));
    expect(
      connection.requests.first.arguments.containsKey('freshNetwork'),
      isFalse,
    );
    expect(connection.requests.last.arguments['freshNetwork'], isTrue);
  });

  test('Venera source read replay stops after the single fresh attempt', () async {
    final connection = _ReplayableSourceReadConnection(recover: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(
        maxResponseBytes: 4096,
        maxConcurrentInvocations: 1,
      ),
    );
    addTearDown(session.close);

    await expectLater(
      session.sources.single.loadChapter('chapter-1'),
      throwsA(isA<Failure>()),
    );

    expect(connection.requests, hasLength(2));
    expect(connection.requests.last.arguments['freshNetwork'], isTrue);
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
    expect(
      (source as BoundedComicResourceSource).resourceOperationTimeout,
      const Duration(seconds: 15),
    );
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

  test('Venera version capability skips non-gnd comic web routes', () async {
    final connection = _FixtureConnection(
      resource: Uint8List.fromList(utf8.encode('<div id="gnd"></div>')),
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
        'id': 'https://example.invalid/photo/12345/',
      }),
    )).replaceAll('=', '');
    final currentId = 'venera:comic:$currentPayload';

    final versionSource = source as ComicVersionSource;
    final versions = await versionSource.findComicVersions(currentId);

    expect(versionSource.supportsComicVersions, isTrue);
    expect(versions, isEmpty);
    expect(connection.operations, isEmpty);
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
    expect(connection.lastRequest?.arguments['useFilters'], isTrue);

    await source.browseWithFilters(
      sectionId: 'latest',
      filterState: const <String, Object?>{},
    );
    expect(connection.lastRequest?.arguments['filterState'], isEmpty);
    expect(connection.lastRequest?.arguments['useFilters'], isTrue);
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
        ExternalPluginRuntimeOperation.retryResource,
      ],
    );
    expect(
      connection.operations,
      isNot(contains(ExternalPluginRuntimeOperation.loadResource)),
    );
  });

  test('Mihon resource refresh requests a fresh source generation plan',
      () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(format: ExternalComicPluginFormat.mihonExtension),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final locator = Uri.parse('mihon:resource:refresh-generation');

    await (source as RefreshableComicResourceSource).refreshResource(locator);

    expect(
      connection.lastRequest?.operation,
      ExternalPluginRuntimeOperation.retryResource,
    );
    expect(connection.lastRequest?.arguments['uri'], locator.toString());
    expect(connection.lastRequest?.arguments['freshGeneration'], isTrue);
  });

  test('Venera resource refresh requests a fresh source generation', () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final locator = Uri.parse('venera-resource:refresh-generation');

    await (source as RefreshableComicResourceSource).refreshResource(locator);

    expect(
      connection.lastRequest?.operation,
      ExternalPluginRuntimeOperation.resolveResource,
    );
    expect(connection.lastRequest?.arguments['uri'], locator.toString());
    expect(connection.lastRequest?.arguments['fresh'], isTrue);
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

  test('resource transport generation advances after source state mutation',
      () async {
    final connection = _FixtureConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final generationSource = source as ComicResourceTransportGenerationSource;
    final configurable = source as ConfigurableComicSource;
    final account = source as AuthenticatableComicSource;

    final initial = generationSource.resourceTransportGenerationIdentity;
    expect(generationSource.resourceTransportGenerationIdentity, same(initial));

    await configurable.updateSetting('mirror', 'https://mirror.invalid');
    final afterSetting = generationSource.resourceTransportGenerationIdentity;
    expect(afterSetting, isNot(same(initial)));

    await account.loginWithCredentials('reader', 'secret');
    final afterLogin = generationSource.resourceTransportGenerationIdentity;
    expect(afterLogin, isNot(same(afterSetting)));

    await account.logout();
    expect(
      generationSource.resourceTransportGenerationIdentity,
      isNot(same(afterLogin)),
    );
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

  test('isolated Venera modifyImage does not occupy the source invocation gate',
      () async {
    final connection = _IsolatedTransformConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final resolver = source as ControlledResolvableComicResourceSource;
    final transformer = source as ControlledTransformingComicResourceSource;
    final transformedUri = Uri.parse('venera-resource:isolated-transform');

    final transformPlan = await resolver.resolveResourceControlled(
      transformedUri,
      control: _MutableTaskControl(priority: 800),
    );
    expect(transformPlan.requiresRuntimeTransform, isTrue);
    final transform = transformer.transformResourceControlled(
      transformedUri,
      Uint8List.fromList(<int>[1, 2, 3, 4]),
      control: _MutableTaskControl(priority: 800),
    );
    await connection.transformStarted.future;

    final current = await resolver.resolveResourceControlled(
      Uri.parse('venera-resource:current-while-transforming'),
      control: _MutableTaskControl(priority: 1000),
    ).timeout(const Duration(milliseconds: 100));
    expect(current.requiresRuntimeTransform, isTrue);
    expect(
      current.diagnostics.containsKey('sourcePlanGateBlockedByOperation'),
      isFalse,
    );
    expect(connection.maxActive, 2);

    connection.releaseTransform.complete();
    expect(await transform, Uint8List.fromList(<int>[1, 2, 3, 4]));
  });

  test('incompatible isolated Venera modifyImage falls back through source gate',
      () async {
    final connection = _IsolatedTransformConnection(
      rejectIsolatedTransform: true,
    );
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final resolver = source as ControlledResolvableComicResourceSource;
    final transformer = source as ControlledTransformingComicResourceSource;
    final uri = Uri.parse('venera-resource:isolated-fallback');
    await resolver.resolveResourceControlled(uri);

    final bytes = Uint8List.fromList(<int>[5, 6, 7]);
    expect(await transformer.transformResourceControlled(uri, bytes), bytes);
    expect(connection.isolatedTransformAttempts, 1);
    expect(connection.canonicalTransformAttempts, 1);
  });

  test(
      'controlled Venera resource plan reports a generic operation occupying the single gate',
      () async {
    final gate = Completer<void>();
    final connection = _SequencedConnection(firstGate: gate.future);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source =
        session.sources.single as ControlledResolvableComicResourceSource;
    final currentControl = _MutableTaskControl(priority: 1000);

    final browse = session.sources.single.browse();
    await Future<void>.delayed(Duration.zero);
    final current = source.resolveResourceControlled(
      Uri.parse('venera-resource:current-behind-browse'),
      control: currentControl,
    );
    await Future<void>.delayed(Duration.zero);

    gate.complete();
    await browse;
    final request = await current;
    expect(
      request.diagnostics['sourcePlanGateBlockedByOperation'],
      ExternalPluginRuntimeOperation.browse.name,
    );
    expect(request.diagnostics['sourcePlanGateBlockedByControlled'], isFalse);
    expect(
      request.diagnostics.containsKey('sourcePlanGateBlockedByPriority'),
      isFalse,
    );
    expect(connection.maxActive, 1);
  });

  test(
      'controlled Venera current preempts an unprioritized generic gate owner',
      () async {
    final connection = _PriorityResolveConnection();
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final controlled = source as ControlledResolvableComicResourceSource;
    final currentControl = _MutableTaskControl(priority: 1000);

    final background = source.loadChapter('chapter-1');
    await connection.firstStarted.future;
    final current = controlled.resolveResourceControlled(
      Uri.parse('venera-resource:current-behind-loadChapter'),
      control: currentControl,
    );

    await expectLater(
      background,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(
      (await current).uri,
      Uri.parse('https://cdn.invalid/current-behind-loadChapter'),
    );
    expect(
      connection.startedUris,
      <String>[
        'loadChapter:chapter-1',
        'venera-resource:current-behind-loadChapter',
      ],
    );
    expect(connection.cancelledRequestIds, hasLength(1));
    expect(connection.maxActive, 1);
  });

  test(
      'controlled Venera metadata yields to current without releasing its permit early',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single;
    final metadata = source as ControlledComicSource;
    final resolver = source as ControlledResolvableComicResourceSource;
    final metadataControl = _MutableTaskControl(priority: 100);
    final currentControl = _MutableTaskControl(priority: 1000);

    final background = metadata.loadChapterControlled(
      'chapter-1',
      control: metadataControl,
    );
    await connection.firstStarted.future;
    final current = resolver.resolveResourceControlled(
      Uri.parse('venera-resource:current-behind-controlled-metadata'),
      control: currentControl,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.cancelledRequestIds, hasLength(1));
    expect(connection.startedUris, <String>['loadChapter:chapter-1']);
    expect(connection.active, 1);

    connection.finishFirst();
    await expectLater(
      background,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(
      (await current).uri,
      Uri.parse('https://cdn.invalid/current-behind-controlled-metadata'),
    );
    expect(connection.maxActive, 1);
  });

  test(
      'controlled Venera resource work cancels active prefetch and admits current before queued prefetch',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single as ControlledResolvableComicResourceSource;
    final firstControl = _MutableTaskControl(priority: 10);
    final secondControl = _MutableTaskControl(priority: 20);
    final currentControl = _MutableTaskControl(priority: 1000);

    final first = source.resolveResourceControlled(
      Uri.parse('venera-resource:prefetch-a'),
      control: firstControl,
    );
    await connection.firstStarted.future;
    final second = source.resolveResourceControlled(
      Uri.parse('venera-resource:prefetch-b'),
      control: secondControl,
    );
    final current = source.resolveResourceControlled(
      Uri.parse('venera-resource:current'),
      control: currentControl,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.startedUris, <String>['venera-resource:prefetch-a']);
    connection.finishFirst();
    // The current request itself preempts the lower-ranked active Venera
    // invocation. Logical page detach does not cancel receiving downloads;
    // cancellation happens only when real current pressure reaches this
    // single-context bottleneck.
    await expectLater(
      first,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect((await current).uri, Uri.parse('https://cdn.invalid/current'));
    expect((await second).uri, Uri.parse('https://cdn.invalid/prefetch-b'));
    expect(
      connection.startedUris,
      <String>[
        'venera-resource:prefetch-a',
        'venera-resource:current',
        'venera-resource:prefetch-b',
      ],
    );
    expect(connection.cancelledRequestIds, hasLength(1));
    expect(connection.maxActive, 1);
  });


  test(
      'controlled Venera previous pressure preempts lower request-plan work without parallel contexts',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source =
        session.sources.single as ControlledResolvableComicResourceSource;
    final activeControl = _MutableTaskControl(priority: 700);
    final queuedControl = _MutableTaskControl(priority: 740);
    final previousControl = _MutableTaskControl(priority: 780);

    final active = source.resolveResourceControlled(
      Uri.parse('venera-resource:active-700'),
      control: activeControl,
    );
    await connection.firstStarted.future;
    final queued = source.resolveResourceControlled(
      Uri.parse('venera-resource:queued-740'),
      control: queuedControl,
    );
    final previous = source.resolveResourceControlled(
      Uri.parse('venera-resource:previous-780'),
      control: previousControl,
    );
    await Future<void>.delayed(Duration.zero);

    connection.finishFirst();
    await expectLater(
      active,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect((await previous).uri, Uri.parse('https://cdn.invalid/previous-780'));
    expect((await queued).uri, Uri.parse('https://cdn.invalid/queued-740'));
    expect(
      connection.startedUris,
      <String>[
        'venera-resource:active-700',
        'venera-resource:previous-780',
        'venera-resource:queued-740',
      ],
    );
    expect(connection.cancelledRequestIds, hasLength(1));
    expect(connection.maxActive, 1);
  });

  test(
      'controlled Venera previous pressure respects the forty point preemption threshold',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source =
        session.sources.single as ControlledResolvableComicResourceSource;
    final activeControl = _MutableTaskControl(priority: 760);
    final previousControl = _MutableTaskControl(priority: 780);

    final active = source.resolveResourceControlled(
      Uri.parse('venera-resource:active-760'),
      control: activeControl,
    );
    await connection.firstStarted.future;
    final previous = source.resolveResourceControlled(
      Uri.parse('venera-resource:previous-threshold-780'),
      control: previousControl,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.cancelledRequestIds, isEmpty);
    expect(connection.startedUris, <String>['venera-resource:active-760']);
    connection.finishFirst();
    expect((await active).uri, Uri.parse('https://cdn.invalid/active-760'));
    expect(
      (await previous).uri,
      Uri.parse('https://cdn.invalid/previous-threshold-780'),
    );
    expect(connection.maxActive, 1);
  });

  test(
      'queued Venera request promoted to current re-evaluates active preemption',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source =
        session.sources.single as ControlledResolvableComicResourceSource;
    final activeControl = _MutableTaskControl(priority: 760);
    final promotedControl = _MutableTaskControl(priority: 780);

    final active = source.resolveResourceControlled(
      Uri.parse('venera-resource:active-dynamic-760'),
      control: activeControl,
    );
    await connection.firstStarted.future;
    final promoted = source.resolveResourceControlled(
      Uri.parse('venera-resource:promoted-current'),
      control: promotedControl,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.cancelledRequestIds, isEmpty);
    promotedControl.updatePriority(900);
    await Future<void>.delayed(Duration.zero);
    promotedControl.updatePriority(780);
    await Future<void>.delayed(Duration.zero);
    promotedControl.updatePriority(900);
    await Future<void>.delayed(Duration.zero);
    expect(
      connection.cancelledRequestIds,
      isEmpty,
      reason: 'transition jitter must not cause irreversible plan cancellation',
    );

    promotedControl.updatePriority(1000);
    await Future<void>.delayed(Duration.zero);

    expect(connection.cancelledRequestIds, hasLength(1));
    expect(
      connection.startedUris,
      <String>['venera-resource:active-dynamic-760'],
      reason: 'priority change requests cancellation but cannot release the '
          'single Venera permit before physical exit',
    );
    expect(connection.maxActive, 1);

    connection.finishFirst();
    await expectLater(
      active,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    final promotedRequest = await promoted;
    expect(
      promotedRequest.uri,
      Uri.parse('https://cdn.invalid/promoted-current'),
    );
    expect(promotedRequest.diagnostics['sourcePlanHookMicros'], 1200);
    expect(promotedRequest.diagnostics['sourcePlanBridgeNetworkMicros'], 800);
    expect(promotedRequest.diagnostics['sourcePlanBridgeNetworkCalls'], 2);
    expect(promotedRequest.diagnostics['sourcePlanBridgeNetworkCacheHits'], 1);
    expect(promotedRequest.diagnostics['sourcePlanBridgeNetworkOriginCalls'], 1);
    expect(
      promotedRequest.diagnostics['sourcePlanBridgeNetworkCallSummary'],
      'GET:origin:500|POST:cache:300',
    );
    expect(promotedRequest.diagnostics['sourcePlanGateWaitMicros'], isA<int>());
    expect(
      promotedRequest.diagnostics['sourcePlanRuntimeInvocationMicros'],
      isA<int>(),
    );
    expect(connection.maxActive, 1);
  });

  test(
      'active Venera current handoff re-evaluates preemption when the old current demotes',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source =
        session.sources.single as ControlledResolvableComicResourceSource;
    final oldCurrentControl = _MutableTaskControl(priority: 1000);
    final newCurrentControl = _MutableTaskControl(priority: 1000);

    final oldCurrent = source.resolveResourceControlled(
      Uri.parse('venera-resource:old-current'),
      control: oldCurrentControl,
    );
    await connection.firstStarted.future;
    final newCurrent = source.resolveResourceControlled(
      Uri.parse('venera-resource:new-current'),
      control: newCurrentControl,
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      connection.cancelledRequestIds,
      isEmpty,
      reason: 'two current-class requests do not preempt until the viewport '
          'commits the old current demotion',
    );

    oldCurrentControl.updatePriority(820);
    await Future<void>.delayed(Duration.zero);

    expect(connection.cancelledRequestIds, hasLength(1));
    expect(
      connection.startedUris,
      <String>['venera-resource:old-current'],
      reason: 'demotion requests cancellation but the single Venera context '
          'must remain occupied until the old invocation physically exits',
    );
    expect(connection.maxActive, 1);

    connection.finishFirst();
    await expectLater(
      oldCurrent,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(
      (await newCurrent).uri,
      Uri.parse('https://cdn.invalid/new-current'),
    );
    expect(
      connection.startedUris,
      <String>[
        'venera-resource:old-current',
        'venera-resource:new-current',
      ],
    );
    expect(connection.maxActive, 1);
  });

  test(
      'active Venera demotion does not turn viewport jitter into plan preemption',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source =
        session.sources.single as ControlledResolvableComicResourceSource;
    final activeControl = _MutableTaskControl(priority: 820);
    final previousControl = _MutableTaskControl(priority: 780);

    final active = source.resolveResourceControlled(
      Uri.parse('venera-resource:active-dynamic-820'),
      control: activeControl,
    );
    await connection.firstStarted.future;
    final previous = source.resolveResourceControlled(
      Uri.parse('venera-resource:waiting-previous-780'),
      control: previousControl,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.cancelledRequestIds, isEmpty);
    activeControl.updatePriority(700);
    await Future<void>.delayed(Duration.zero);

    expect(
      connection.cancelledRequestIds,
      isEmpty,
      reason: 'active demotion is reversible viewport state and must not cancel',
    );
    expect(connection.startedUris, <String>['venera-resource:active-dynamic-820']);
    expect(connection.maxActive, 1);

    connection.finishFirst();
    expect(
      (await active).uri,
      Uri.parse('https://cdn.invalid/active-dynamic-820'),
    );
    expect(
      (await previous).uri,
      Uri.parse('https://cdn.invalid/waiting-previous-780'),
    );
    expect(connection.cancelledRequestIds, isEmpty);
    expect(connection.maxActive, 1);
  });

  test(
      'controlled Venera preemption keeps the single permit until the physical invocation exits',
      () async {
    final connection = _PriorityResolveConnection(releaseOnCancel: false);
    final session = ExternalPluginRuntimeSession(
      plugin: _plugin(),
      connection: connection,
      limits: const ExternalPluginRuntimeLimits(maxConcurrentInvocations: 4),
    );
    addTearDown(session.close);
    final source = session.sources.single as ControlledResolvableComicResourceSource;
    final prefetchControl = _MutableTaskControl(priority: 10);
    final currentControl = _MutableTaskControl(priority: 1000);

    final prefetch = source.resolveResourceControlled(
      Uri.parse('venera-resource:physical-prefetch'),
      control: prefetchControl,
    );
    await connection.firstStarted.future;
    final current = source.resolveResourceControlled(
      Uri.parse('venera-resource:physical-current'),
      control: currentControl,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.cancelledRequestIds, hasLength(1));
    expect(
      connection.startedUris,
      <String>['venera-resource:physical-prefetch'],
      reason: 'requesting cancellation must not release the single Venera permit',
    );
    expect(connection.maxActive, 1);

    connection.finishFirst();
    await expectLater(
      prefetch,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect((await current).uri, Uri.parse('https://cdn.invalid/physical-current'));
    expect(
      connection.startedUris,
      <String>[
        'venera-resource:physical-prefetch',
        'venera-resource:physical-current',
      ],
    );
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

final class _CancelledFailureConnection
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
          code: 'cancelled',
          message: 'runtime request was cancelled',
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

final class _ReplayableSourceReadConnection
    implements ExternalPluginRuntimeConnection {
  _ReplayableSourceReadConnection({this.recover = true});

  final bool recover;
  final List<ExternalPluginRuntimeRequest> requests =
      <ExternalPluginRuntimeRequest>[];

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
    requests.add(request);
    if (requests.length == 1 || !recover) {
      return ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'venera-operation-failed',
          message: 'temporary source metadata parse failure',
          retryable: true,
          details: const <String, Object?>{
            'sourceReadReplayEligible': true,
          },
        ),
      );
    }
    return ExternalPluginRuntimeResponse.success(
      requestId: request.requestId,
      payload: <String, Object?>{
        'comicId': 'comic-1',
        'chapter': <String, Object?>{
          'chapterId': 'chapter-1',
          'comicId': 'comic-1',
          'title': 'Chapter 1',
          'sequence': 0,
          'pageCount': 1,
          'sourceRevision': 'r1',
        },
        'readingDirection': 'topToBottom',
        'pages': <Object?>[
          <String, Object?>{
            'pageId': 'page-1',
            'chapterId': 'chapter-1',
            'index': 0,
            'uri': 'https://cdn.invalid/1.webp',
          },
        ],
      },
    );
  }

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
        ExternalPluginRuntimeOperation.transformResource =>
          request.arguments['bytes']!,
        ExternalPluginRuntimeOperation.retryResource =>
          (request.arguments['uri'] as String).startsWith('mihon:resource:')
              ? const <String, Object?>{
                  'available': true,
                  'request': <String, Object?>{
                    'url': 'https://cdn.invalid/1.webp',
                    'method': 'GET',
                    'headers': <String, Object?>{},
                    'body': null,
                    'requiresRuntimeTransform': false,
                  },
                }
              : const <String, Object?>{'available': false},
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

final class _MutableTaskControl implements PriorityObservableTaskControl {
  _MutableTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();
  final StreamController<int> _priorityChanges =
      StreamController<int>.broadcast(sync: true);
  @override
  int priority;

  @override
  Stream<int> get priorityChanges => _priorityChanges.stream;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void updatePriority(int value) {
    if (priority == value) return;
    priority = value;
    _priorityChanges.add(value);
  }

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class _PriorityResolveConnection
    implements CancellableExternalPluginRuntimeConnection {
  _PriorityResolveConnection({this.releaseOnCancel = true});

  final bool releaseOnCancel;
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> _firstRelease = Completer<void>();
  final List<String> startedUris = <String>[];
  final List<String> cancelledRequestIds = <String>[];
  final Set<String> _cancelledRequestIds = <String>{};
  String? _firstRequestId;
  int active = 0;
  int maxActive = 0;

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
    final rawUri = request.arguments['uri'];
    final chapterId = request.arguments['chapterId'];
    final isResolve =
        request.operation == ExternalPluginRuntimeOperation.resolveResource &&
        rawUri is String;
    final isChapter =
        request.operation == ExternalPluginRuntimeOperation.loadChapter &&
        chapterId is String;
    if (!isResolve && !isChapter) {
      throw StateError('priority fixture accepts resolveResource/loadChapter only');
    }
    startedUris.add(isResolve ? rawUri : 'loadChapter:$chapterId');
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (_firstRequestId == null) {
        _firstRequestId = request.requestId;
        firstStarted.complete();
        await _firstRelease.future;
      }
      if (_cancelledRequestIds.contains(request.requestId)) {
        return ExternalPluginRuntimeResponse.failure(
          requestId: request.requestId,
          error: ExternalPluginRuntimeError(
            code: 'runtime-request-cancelled',
            message: 'fixture request was preempted',
          ),
        );
      }
      if (isChapter) {
        return ExternalPluginRuntimeResponse.success(
          requestId: request.requestId,
          payload: <String, Object?>{
            'comicId': 'comic-1',
            'chapter': <String, Object?>{
              'chapterId': chapterId,
              'title': 'Chapter',
              'pageCount': 1,
              'sourceRevision': 'r1',
            },
            'pages': <Object?>[
              <String, Object?>{
                'chapterId': chapterId,
                'pageId': 'page-1',
                'index': 0,
                'uri': 'https://cdn.invalid/page-1.webp',
              },
            ],
          },
        );
      }
      final suffix = Uri.parse(rawUri as String).path.split(':').last;
      return ExternalPluginRuntimeResponse.success(
        requestId: request.requestId,
        payload: <String, Object?>{
          'url': 'https://cdn.invalid/$suffix',
          'method': 'GET',
          'headers': <String, Object?>{},
          'body': null,
          'requiresRuntimeTransform': false,
          '__zicDiagnostics': <String, Object?>{
            'sourcePlanHookMicros': 1200,
            'sourcePlanBridgeNetworkMicros': 800,
            'sourcePlanBridgeNetworkCalls': 2,
            'sourcePlanBridgeNetworkCacheHits': 1,
            'sourcePlanBridgeNetworkOriginCalls': 1,
            'sourcePlanBridgeNetworkCallSummary':
                'GET:origin:500|POST:cache:300',
          },
        },
      );
    } finally {
      active--;
    }
  }

  @override
  Future<void> cancel(String requestId) async {
    cancelledRequestIds.add(requestId);
    _cancelledRequestIds.add(requestId);
    if (releaseOnCancel &&
        requestId == _firstRequestId &&
        !_firstRelease.isCompleted) {
      _firstRelease.complete();
    }
  }

  void finishFirst() {
    if (!_firstRelease.isCompleted) _firstRelease.complete();
  }

  @override
  Future<void> close() async {
    if (!_firstRelease.isCompleted) _firstRelease.complete();
  }
}

final class _IsolatedTransformConnection
    implements ExternalPluginRuntimeConnection {
  _IsolatedTransformConnection({this.rejectIsolatedTransform = false});

  final bool rejectIsolatedTransform;
  final Completer<void> transformStarted = Completer<void>();
  final Completer<void> releaseTransform = Completer<void>();
  int active = 0;
  int maxActive = 0;
  int isolatedTransformAttempts = 0;
  int canonicalTransformAttempts = 0;

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
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (request.operation == ExternalPluginRuntimeOperation.resolveResource) {
        return ExternalPluginRuntimeResponse.success(
          requestId: request.requestId,
          payload: <String, Object?>{
            'url': 'https://cdn.invalid/${request.arguments['uri']}',
            'method': 'GET',
            'headers': const <String, Object?>{},
            'body': null,
            'requiresRuntimeTransform': true,
            '__zicIsolatedModifyImage':
                'let modifyImage = (image) => image',
          },
        );
      }
      if (request.operation == ExternalPluginRuntimeOperation.transformResource) {
        final isolated =
            request.arguments['__zicIsolatedModifyImage'] is String;
        if (isolated) {
          isolatedTransformAttempts++;
          if (rejectIsolatedTransform) {
            return ExternalPluginRuntimeResponse.failure(
              requestId: request.requestId,
              error: ExternalPluginRuntimeError(
                code: 'venera-isolated-transform-incompatible',
                message: 'fixture requires source context',
              ),
            );
          }
          if (!transformStarted.isCompleted) transformStarted.complete();
          await releaseTransform.future;
        } else {
          canonicalTransformAttempts++;
        }
        return ExternalPluginRuntimeResponse.success(
          requestId: request.requestId,
          payload: request.arguments['bytes']!,
        );
      }
      throw UnimplementedError('${request.operation}');
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    if (!releaseTransform.isCompleted) releaseTransform.complete();
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
            <String, Object?>{
              'url': 'https://cdn.invalid/${request.arguments['uri']}',
              'method': 'GET',
              'headers': <String, Object?>{},
              'body': null,
              'requiresRuntimeTransform': false,
            },
          ExternalPluginRuntimeOperation.transformResource =>
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
