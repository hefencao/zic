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

ExternalComicPluginCatalogEntry _plugin() =>
    ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
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
  }) : resource = resource ?? Uint8List.fromList(<int>[82, 73, 70, 70]);

  final bool mismatchRequestId;
  final Uint8List resource;
  final Future<void>? block;
  final Future<void>? closeBlock;
  final List<ExternalPluginRuntimeOperation> operations =
      <ExternalPluginRuntimeOperation>[];
  bool closed = false;
  int closeCalls = 0;

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
            'pages': <Object?>[
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
            ],
          },
        ExternalPluginRuntimeOperation.loadResource => resource,
      },
    );
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
