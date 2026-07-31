import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:testkit/testkit.dart';
import 'package:transport/transport.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download_job_test_');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  DownloadSession createSession() => DownloadSession(
        id: DownloadId(
          content: const ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: 'page',
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/page.webp'),
        ),
        artifact: Artifact(
          partialPath: '${temp.path}/partial/page.webp',
          finalPath: '${temp.path}/cache/page.webp',
        ),
        clock: FakeMonoClock(),
      );

  test('resumes a durable partial with matching validators', () async {
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0,
      0,
      0,
      0,
      ...'WEBP'.codeUnits,
      1,
      2,
      3,
      4,
    ];
    final session = createSession();
    final broken = FakeTransport(
      bytes: bytes,
      chunkSize: 3,
      failAfterBytes: 5,
      validators: const Validators(etag: 'v1'),
    );

    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );
    expect(session.committedLength, 5);
    expect(session.artifact.hasOpenWriter, isFalse);

    final resumed = FakeTransport(
      bytes: bytes,
      chunkSize: 4,
      validators: const Validators(etag: 'v1'),
    );
    final result = await DownloadJob(transport: resumed, session: session).run();

    expect(result.state, DownloadState.promoted);
    expect(result.activeRun, isFalse);
    expect(result.contentKind, ContentKind.webp);
    expect(resumed.requests, hasLength(1));
    expect(resumed.requests.single.range?.start, 5);
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

  test('validator mismatch discards the partial and restarts from zero', () async {
    final bytes = List<int>.generate(20, (index) => index);
    final session = createSession();
    final broken = FakeTransport(
      bytes: bytes,
      failAfterBytes: 6,
      validators: const Validators(etag: 'v1'),
    );
    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );

    final changed = FakeTransport(
      bytes: bytes,
      validators: const Validators(etag: 'v2'),
    );
    final result = await DownloadJob(transport: changed, session: session).run();

    expect(result.state, DownloadState.promoted);
    expect(changed.requests, hasLength(2));
    expect(changed.requests.first.range?.start, 6);
    expect(changed.requests.last.range, isNull);
    expect(changed.discardCount, 1);
    expect(result.epoch, const SourceEpoch(1));
  });
  test('explicit cancellation closes a stalled response stream', () async {
    final session = createSession();
    final transport = _BlockingTransport();
    final cancel = CancelToken();
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: cancel,
    );

    await transport.firstChunk.future;
    cancel.cancel();

    await expectLater(
      run,
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    await transport.cancelled.future.timeout(const Duration(seconds: 1));
  });

  test('promotes a complete restored partial without another request', () async {
    final bytes = List<int>.generate(12, (index) => index + 1);
    final session = createSession();
    await session.restore();
    await session.bindResponse(
      validators: const Validators(etag: 'v1'),
      totalLength: bytes.length,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes);
    await session.fail(
      writer,
      const Failure(code: ErrorCode.network, message: 'simulated crash'),
    );

    final transport = FakeTransport(bytes: bytes);
    final result = await DownloadJob(
      transport: transport,
      session: session,
    ).run();

    expect(result.state, DownloadState.promoted);
    expect(transport.requests, isEmpty);
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

}

final class _BlockingTransport implements Transport {
  final Completer<void> firstChunk = Completer<void>();
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        controller.add(<int>[1, 2, 3]);
        if (!firstChunk.isCompleted) firstChunk.complete();
      },
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    return ByteResponse(
      bytes: controller.stream,
      statusCode: HttpStatus.ok,
      rangeStart: 0,
      totalLength: 6,
    );
  }
}
