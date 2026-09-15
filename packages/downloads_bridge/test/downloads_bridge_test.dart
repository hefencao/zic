import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('rhttp direct source open owns a finite pre-header deadline', () async {
    final neverReady = Completer<void>();
    final transport = RhttpSourceResourceDirectTransport(
      preparePlatform: () => neverReady.future,
      responseHeaderTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(transport.close);

    expect(transport, isA<SelfBoundedSourceResourceDirectTransport>());
    await expectLater(
      transport.open(
        ComicResourceRequest(uri: Uri.parse('https://example.invalid/page')),
      ),
      throwsA(
        isA<Failure>()
            .having((error) => error.code, 'code', ErrorCode.network)
            .having(
              (error) => error.message,
              'message',
              contains('client initialization timed out'),
            ),
      ),
    );
  });

  test('rhttp direct source open does not follow source-owned redirects',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var finalRequests = 0;
    unawaited(server.forEach((request) async {
      if (request.uri.path == '/start') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/final',
        );
      } else {
        finalRequests++;
        request.response.statusCode = HttpStatus.ok;
        request.response.add(<int>[0xff, 0xd8, 0xff, 0xd9]);
      }
      await request.response.close();
    }));
    final transport = RhttpSourceResourceDirectTransport();
    addTearDown(transport.close);
    final uri = Uri.parse(
      'http://${server.address.address}:${server.port}/start',
    );

    await expectLater(
      transport.open(
        ComicResourceRequest(
          uri: uri,
          requiresRuntimeTransform: true,
        ),
      ),
      throwsA(
        isA<Failure>().having(
          (error) => error.details['sourceClientStateRequired'],
          'source client state required',
          isTrue,
        ),
      ),
    );
    expect(finalRequests, 0);
  });

  test('rhttp direct source open returns Set-Cookie ownership to source client',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(server.forEach((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.add(
        HttpHeaders.setCookieHeader,
        'fixture=session; Path=/',
      );
      request.response.add(const <int>[1, 2, 3, 4]);
      await request.response.close();
    }));
    final transport = RhttpSourceResourceDirectTransport();
    addTearDown(transport.close);
    final uri = Uri.parse(
      'http://${server.address.address}:${server.port}/stateful',
    );

    await expectLater(
      transport.open(
        ComicResourceRequest(
          uri: uri,
          requiresRuntimeTransform: true,
        ),
      ),
      throwsA(
        isA<Failure>().having(
          (error) => error.details['sourceClientStateRequired'],
          'source client state required',
          isTrue,
        ),
      ),
    );
  });

  test('JSON queue adapter restores policy and pending chapters', () async {
    final directory = await Directory.systemTemp.createTemp('zic-whole-queue-');
    addTearDown(() => directory.delete(recursive: true));
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    addTearDown(downloads.close);
    final environment = MutableWholeComicQueueEnvironment(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: false,
        charging: true,
      ),
    );
    addTearDown(environment.close);
    final path = '${directory.path}/queue.json';
    final first = await openPersistentWholeComicDownloadQueue(
      path: path,
      downloads: downloads,
      environment: environment,
    );
    await first.updatePolicy(
      const WholeComicQueuePolicy(
        concurrency: 3,
        network: WholeComicNetworkPolicy.unmetered,
      ),
    );
    await first.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1), _entry(2)],
    );
    await _waitForPhase(first, WholeComicQueuePhase.waitingForPolicy);
    await first.close();

    final reopened = await openPersistentWholeComicDownloadQueue(
      path: path,
      downloads: downloads,
      environment: environment,
    );
    addTearDown(reopened.close);
    expect(reopened.snapshot.policy.concurrency, 3);
    expect(
      reopened.snapshot.policy.network,
      WholeComicNetworkPolicy.unmetered,
    );
    final restored = reopened.snapshot.jobFor('queue-source', 'queue-comic');
    expect(restored, isNotNull);
    expect(restored!.totalChapters, 2);
    expect(restored.phase, WholeComicQueuePhase.waitingForPolicy);
  });
}

Future<void> _waitForPhase(
  WholeComicDownloadQueue queue,
  WholeComicQueuePhase phase,
) async {
  if (queue.snapshot.jobs.any((job) => job.phase == phase)) {
    return;
  }
  await queue.changes.firstWhere(
    (snapshot) => snapshot.jobs.any((job) => job.phase == phase),
  );
}

ImportedLibraryEntry _entry(int chapter) => ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:queue-comic',
        displayName: '第 $chapter 话',
        sourceId: 'queue-source',
        comicId: 'queue-comic',
        comicTitle: '队列漫画',
        chapterId: 'queue-chapter-$chapter',
        sourceRevision: 'queue-r$chapter',
        sequence: chapter,
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '$chapter.bin',
            sourceId: 'memory://queue-$chapter',
            pageId: 'queue-page-$chapter',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 1,
          ),
        ],
      ),
    );
