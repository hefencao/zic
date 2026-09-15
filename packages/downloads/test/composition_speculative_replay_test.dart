import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('hot partial replay uses the composition local-read scheduler', () async {
    final reads = ArtifactCacheReadScheduler(maxActive: 2);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
      localReadScheduler: reads,
    );
    addTearDown(runtime.dispose);
    final id = _id('hot-partial');
    final session = runtime.registry.get(id);
    await session.restore();
    final writer = session.acquireWriter();
    final bytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(512 * 1024, 7),
    ];
    await session.append(writer, 0, bytes);
    await session.pause(writer);

    final blockerA = await reads.acquire(priority: () => 1000);
    final blockerB = await reads.acquire(priority: () => 1000);
    final control = CancelToken(priority: 1000);
    final source = runtime.artifactReplayRangeSourceWithControl(
      priorityFor: (_) => 1000,
    );
    final stream = await source(
      session,
      0,
      256 * 1024,
      chunkSize: 256 * 1024,
      control: control,
    );
    final iterator = StreamIterator<List<int>>(stream);
    var started = false;
    final next = iterator.moveNext().then((value) {
      started = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    expect(reads.pendingCount, 1);

    blockerA.release();
    expect(await next, isTrue);
    expect(iterator.current.length, 256 * 1024);
    await iterator.cancel();
    blockerB.release();
  });

  test('hot partial replay publishes one decoder bootstrap quantum when budget is saturated',
      () async {
    const quantum = 256 * 1024;
    final budget = SpeculativeEncodedReadBudget(limitBytes: quantum);
    final reads = ArtifactCacheReadScheduler(maxActive: 2);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
      localReadScheduler: reads,
      speculativeEncodedReadBudget: budget,
    );
    addTearDown(runtime.dispose);

    final blockerControl = CancelToken(priority: 700);
    final blocker = budget.accountFor(
      blockerControl,
      control: blockerControl,
    );
    blocker.recordRead(quantum);
    addTearDown(() {
      blocker.close();
      blockerControl.cancel();
    });
    expect(budget.activeSpeculativeBytes, quantum);

    final id = _id('hot-partial-bootstrap');
    final session = runtime.registry.get(id);
    await session.restore();
    final writer = session.acquireWriter();
    final bytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled((2 * quantum) - 12, 7),
    ];
    await session.append(writer, 0, bytes);
    await session.pause(writer);

    final control = CancelToken(priority: 820);
    addTearDown(control.cancel);
    final source = runtime.artifactReplayRangeSourceWithControl(
      priorityFor: (_) => control.priority,
    );
    final stream = await source(
      session,
      0,
      2 * quantum,
      chunkSize: quantum,
      control: control,
    );
    final iterator = StreamIterator<List<int>>(stream);
    addTearDown(iterator.cancel);

    expect(await iterator.moveNext(), isTrue,
        reason: 'existing hot bytes must publish one bounded decoder probe even when older speculative work filled the budget');
    expect(iterator.current.length, quantum);
    expect(budget.activeSpeculativeBytes, 2 * quantum,
        reason: 'the one-quantum bootstrap may cross the cap but remains charged afterward');

    var secondCompleted = false;
    final second = iterator.moveNext().then((value) {
      secondCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(secondCompleted, isFalse,
        reason: 'only the first bounded local replay quantum bypasses the cap');

    control.updatePriority(900);
    expect(await second, isTrue,
        reason: 'normal foreground promotion still releases the remaining replay');
    expect(iterator.current.length, quantum);
  });

  test('resident WebP replay publishes one decoder bootstrap quantum when budget is saturated',
      () async {
    const quantum = 256 * 1024;
    final budget = SpeculativeEncodedReadBudget(limitBytes: quantum);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
      speculativeEncodedReadBudget: budget,
    );
    addTearDown(runtime.dispose);

    final blockerControl = CancelToken(priority: 700);
    final blocker = budget.accountFor(
      blockerControl,
      control: blockerControl,
    );
    blocker.recordRead(quantum);
    addTearDown(() {
      blocker.close();
      blockerControl.cancel();
    });

    final id = _id('resident-bootstrap');
    final session = runtime.registry.get(id);
    final bytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled((2 * quantum) - 12, 9),
    ];
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.length,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
      residentReplayRangeChunks: (start, endExclusive) async =>
          Stream<List<int>>.value(bytes.sublist(start, endExclusive)),
      residentReplayAccessMode: 'direct',
    );
    expect(session.contentKind, ContentKind.webp);

    final control = CancelToken(priority: 820);
    addTearDown(control.cancel);
    final source = runtime.residentReplayRangeSourceWithControl(
      priorityFor: (_) => control.priority,
    );
    final firstStream = await source(
      session,
      0,
      quantum,
      control: control,
    );
    final first = StreamIterator<List<int>>(firstStream);
    expect(await first.moveNext(), isTrue,
        reason: 'the initial resident decoder probe must not wait for older speculative charges');
    expect(first.current.length, quantum);
    await first.cancel();
    expect(budget.activeSpeculativeBytes, 2 * quantum);

    final secondStream = await source(
      session,
      quantum,
      2 * quantum,
      control: control,
    );
    final second = StreamIterator<List<int>>(secondStream);
    addTearDown(second.cancel);
    var secondCompleted = false;
    final secondNext = second.moveNext().then((value) {
      secondCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(secondCompleted, isFalse,
        reason: 'resident replay after the bootstrap quantum remains budget-gated');

    control.updatePriority(900);
    expect(await secondNext, isTrue);
    expect(second.current.length, quantum);
  });

  test('resident WebP reentry reuses the central generation bootstrap prefix',
      () async {
    const quantum = 256 * 1024;
    final cache = ArtifactCacheManager(backend: _EmptyArtifactCacheBackend());
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
    );
    addTearDown(runtime.dispose);

    final id = _id('resident-reentry-prefix');
    final session = runtime.registry.get(id);
    final bytes = Uint8List.fromList(<int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled((2 * quantum) - 12, 11),
    ]);
    var physicalReads = 0;
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: Uint8List.sublistView(bytes, 0, 64),
      residentReplayRangeChunks: (start, endExclusive) async {
        physicalReads++;
        return Stream<List<int>>.value(
          Uint8List.sublistView(bytes, start, endExclusive),
        );
      },
      residentReplayAccessMode: 'direct',
    );
    final firstToken = session.residentReplayGenerationToken;
    expect(firstToken, isNotNull);

    final source = runtime.residentReplayRangeSource(
      priorityFor: (_) => 1000,
    );
    final first = await source(session, 0, quantum).then(_collect);
    expect(first, Uint8List.sublistView(bytes, 0, quantum));
    expect(physicalReads, 1);
    expect(cache.residentReplayPrefixEntryCount, 1);

    final reentry = await source(session, 0, quantum).then(_collect);
    expect(reentry, Uint8List.sublistView(bytes, 0, quantum));
    expect(physicalReads, 1,
        reason: 'same immutable physical generation must not re-read the bootstrap prefix from storage');

    await session.reset(deleteFinalArtifact: false);
    expect(session.residentReplayGenerationToken, isNull);

    physicalReads = 0;
    const stableGeneration = 'sealed-generation-a';
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: Uint8List.sublistView(bytes, 0, 64),
      residentReplayRangeChunks: (start, endExclusive) async {
        physicalReads++;
        return Stream<List<int>>.value(
          Uint8List.sublistView(bytes, start, endExclusive),
        );
      },
      residentReplayAccessMode: 'direct',
      residentReplayCacheKey: stableGeneration,
    );
    final stableFirst = await source(session, 0, quantum).then(_collect);
    expect(stableFirst, Uint8List.sublistView(bytes, 0, quantum));
    expect(physicalReads, 1);

    await session.reset(deleteFinalArtifact: false);
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: Uint8List.sublistView(bytes, 0, 64),
      residentReplayRangeChunks: (start, endExclusive) async {
        physicalReads++;
        return Stream<List<int>>.value(
          Uint8List.sublistView(bytes, start, endExclusive),
        );
      },
      residentReplayAccessMode: 'direct',
      residentReplayCacheKey: stableGeneration,
    );
    final stableReentry = await source(session, 0, quantum).then(_collect);
    expect(stableReentry, Uint8List.sublistView(bytes, 0, quantum));
    expect(physicalReads, 1,
        reason: 'a recreated session for the same sealed generation should reuse the central bootstrap prefix');

    await session.reset(deleteFinalArtifact: false);
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: Uint8List.sublistView(bytes, 0, 64),
      residentReplayRangeChunks: (start, endExclusive) async {
        physicalReads++;
        return Stream<List<int>>.value(
          Uint8List.sublistView(bytes, start, endExclusive),
        );
      },
      residentReplayAccessMode: 'direct',
      residentReplayCacheKey: 'sealed-generation-b',
    );
    final changedGeneration = await source(session, 0, quantum).then(_collect);
    expect(changedGeneration, Uint8List.sublistView(bytes, 0, quantum));
    expect(physicalReads, 2,
        reason: 'a different sealed generation key must not reuse the old prefix');
  });

  test('bound resident replay splits decoder range into 256 KiB physical quanta',
      () async {
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
    );
    addTearDown(runtime.dispose);
    final id = _id('bounded');
    final session = runtime.registry.get(id);
    const total = 700 * 1024;
    final ranges = <(int, int)>[];
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: total,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: const <int>[0xff, 0xd8, 0xff],
      residentReplayRangeChunks: (start, endExclusive) async {
        ranges.add((start, endExclusive));
        return Stream<List<int>>.value(
          Uint8List(endExclusive - start),
        );
      },
      residentReplayAccessMode: 'saf',
    );
    final control = CancelToken(priority: 700);
    final source = runtime.residentReplayRangeSourceWithControl(
      priorityFor: (_) => 700,
    );
    final stream = await source(
      session,
      0,
      total,
      control: control,
    );
    var received = 0;
    await for (final chunk in stream) {
      received += chunk.length;
    }

    expect(received, total);
    expect(
      ranges,
      <(int, int)>[
        (0, 256 * 1024),
        (256 * 1024, 512 * 1024),
        (512 * 1024, total),
      ],
    );
  });

  test('bound resident replay cancellation prevents the next physical quantum',
      () async {
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
    );
    addTearDown(runtime.dispose);
    final id = _id('cancelled');
    final session = runtime.registry.get(id);
    const total = 700 * 1024;
    final ranges = <(int, int)>[];
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: total,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: const <int>[0xff, 0xd8, 0xff],
      residentReplayRangeChunks: (start, endExclusive) async {
        ranges.add((start, endExclusive));
        return Stream<List<int>>.value(
          Uint8List(endExclusive - start),
        );
      },
      residentReplayAccessMode: 'saf',
    );
    final control = CancelToken(priority: 700);
    final source = runtime.residentReplayRangeSourceWithControl(
      priorityFor: (_) => 700,
    );
    final stream = await source(
      session,
      0,
      total,
      control: control,
    );
    final iterator = StreamIterator<List<int>>(stream);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.length, 256 * 1024);
    control.cancel();
    await expectLater(
      iterator.moveNext(),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(ranges, <(int, int)>[(0, 256 * 1024)]);
    await iterator.cancel();
  });

  test('local artifact prewarm joins one restore and never admits network',
      () async {
    final store = _BlockingPartialDownloadStore();
    final net = NetLane(maxActive: 2);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: store,
      net: net,
    );
    addTearDown(runtime.dispose);
    final id = _id('local-prewarm-single-flight');
    final expectedSession = runtime.sessionFor(id);

    final first = runtime.prewarmLocalArtifact(id);
    await store.started.future;
    expect(identical(runtime.sessionFor(id), expectedSession), isTrue,
        reason: 'prewarm must keep one physical session owner');
    final second = runtime.prewarmLocalArtifact(id);
    await Future<void>.delayed(Duration.zero);
    expect(store.openCalls, 1,
        reason: 'the second prewarm must join the same session+epoch restore');
    expect(runtime.owner.taskKeyFor(id), isNull,
        reason: 'local-only prewarm must not create network admission');

    store.release.complete();
    expect(await first, isFalse);
    expect(await second, isFalse);
    expect(store.maxConcurrentOpenCalls, 1,
        reason: 'one restore may perform sequential probes, but never overlap a duplicate restore');
    expect(runtime.owner.taskKeyFor(id), isNull);
  });
}

DownloadId _id(String page) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: page,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/$page.webp'),
    );

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

final class _EmptyArtifactCacheBackend implements ArtifactCacheBackend {
  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async => null;

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _BlockingPartialDownloadStore implements PartialDownloadStore {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int openCalls = 0;
  int activeOpenCalls = 0;
  int maxConcurrentOpenCalls = 0;

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) async {
    openCalls += 1;
    activeOpenCalls += 1;
    if (activeOpenCalls > maxConcurrentOpenCalls) {
      maxConcurrentOpenCalls = activeOpenCalls;
    }
    try {
      if (!started.isCompleted) started.complete();
      await release.future;
      return null;
    } finally {
      activeOpenCalls -= 1;
    }
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) async {}

  @override
  Future<void> invalidatePartialDownload(DownloadId id) async {}
}
