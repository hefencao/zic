import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('defaults retain a VibeVenera-sized ten-page byte window', () {
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );

    expect(manager.memoryMaxEntries, 10);
    expect(manager.memoryMaxBytes, 256 * 1024 * 1024);
  });

  test('routes memory before backend and validates exact length', () async {
    final id = _id('memory');
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[1, 2, 3]),
    });
    final manager = ArtifactCacheManager(backend: backend);

    final first = await manager.readForeground(id);
    final second = await manager.readForeground(id);

    expect(first?.memoryHit, isFalse);
    expect(second?.memoryHit, isTrue);
    expect(backend.openCalls, 1);
    expect(await manager.contains(id: id, expectedLength: 3), isTrue);
    expect(await manager.contains(id: id, expectedLength: 4), isFalse);
    expect(await manager.containsBackendExact(id: id, expectedLength: 3), isTrue);
  });

  test('memory visibility does not masquerade as backend persistence', () async {
    final id = _id('memory-only');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    manager.remember(id: id, bytes: Uint8List.fromList(<int>[1, 2, 3]));

    expect(await manager.contains(id: id, expectedLength: 3), isTrue);
    expect(
      await manager.containsBackendExact(id: id, expectedLength: 3),
      isFalse,
    );
  });

  test('presentation file lease bypasses hot encoded-byte materialization',
      () async {
    final id = _id('presentation-file-hot-memory');
    var releases = 0;
    final backend = _Backend(
      <DownloadId, Uint8List>{
        id: Uint8List.fromList(<int>[1, 2, 3]),
      },
      presentationOpen: (openedId, bytes) async {
        expect(openedId, id);
        return ArtifactCachePresentationFileLease(
          path: '/proc/self/fd/41',
          length: bytes.lengthInBytes,
          width: 1200,
          height: 1800,
          release: () async => releases++,
        );
      },
    );
    final manager = ArtifactCacheManager(backend: backend);

    await manager.readForeground(id);
    expect(manager.lookupMemory(id), isNotNull);
    final priorReadAllCalls = backend.readAllCalls;

    final lease = await manager.openPresentationFile(id);

    expect(lease, isNotNull);
    expect(lease!.path, '/proc/self/fd/41');
    expect(lease.width, 1200);
    expect(lease.height, 1800);
    expect(backend.readAllCalls, priorReadAllCalls);
    await lease.release();
    expect(releases, 1);
  });

  test('presentation file lease rejects a generation invalidated while opening',
      () async {
    final id = _id('presentation-file-stale-generation');
    final opened = Completer<void>();
    final releaseOpen = Completer<void>();
    var releases = 0;
    final backend = _Backend(
      <DownloadId, Uint8List>{
        id: Uint8List.fromList(<int>[4, 5, 6]),
      },
      presentationOpen: (openedId, bytes) async {
        if (!opened.isCompleted) opened.complete();
        await releaseOpen.future;
        return ArtifactCachePresentationFileLease(
          path: '/proc/self/fd/42',
          length: bytes.lengthInBytes,
          width: 1200,
          height: 1800,
          release: () async => releases++,
        );
      },
    );
    final manager = ArtifactCacheManager(backend: backend);

    final pending = manager.openPresentationFile(id);
    await opened.future;
    await manager.invalidate(id);
    releaseOpen.complete();

    expect(await pending, isNull);
    expect(releases, 1);
  });

  test('memory cache protects its byte buffers with unmodifiable views', () async {
    final id = _id('memory-ownership');
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );
    final input = Uint8List.fromList(<int>[1, 2, 3]);
    manager.remember(id: id, bytes: input);

    final first = manager.lookupMemory(id);
    expect(first, <int>[1, 2, 3]);
    expect(() => first![1] = 8, throwsUnsupportedError);
  });

  test('memory stream reads return unmodifiable byte buffers', () async {
    final id = _id('memory-stream-ownership');
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{
        id: Uint8List.fromList(<int>[1, 2, 3]),
      }),
    );
    await manager.readForeground(id);

    final read = await manager.readForeground(id);
    expect(read!.bytes, <int>[1, 2, 3]);
    expect(() => read.bytes[0] = 9, throwsUnsupportedError);
  });

  test('backend read results return unmodifiable byte buffers', () async {
    final id = _id('backend-read-ownership');
    final backendBytes = Uint8List.fromList(<int>[1, 2, 3]);
    final backend = _Backend(<DownloadId, Uint8List>{id: backendBytes});
    final manager = ArtifactCacheManager(backend: backend);

    final read = await manager.readForeground(id);
    expect(read!.bytes, <int>[1, 2, 3]);
    expect(() => read.bytes[0] = 9, throwsUnsupportedError);
  });

  test('replacing same-length bytes does not inherit old durable provenance',
      () async {
    final id = _id('durability-provenance');
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );

    await manager.storePromotedArtifact(
      id: id,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    manager.remember(
      id: id,
      bytes: Uint8List.fromList(<int>[9, 9, 9]),
    );

    final lookup = await manager.lookup(id);
    expect(lookup, isNotNull);
    expect(lookup!.tier, ArtifactCacheTier.memory);
    expect(lookup.durable, isFalse);
  });

  test('joins concurrent foreground materialization in the manager', () async {
    final id = _id('join');
    final gate = Completer<void>();
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[4, 5, 6]),
    }, readGate: gate);
    final manager = ArtifactCacheManager(backend: backend);

    final first = manager.readForeground(id);
    final second = manager.readForeground(id);
    gate.complete();

    expect((await first)?.bytes, <int>[4, 5, 6]);
    expect((await second)?.joined, isTrue);
    expect(backend.readAllCalls, 1);
  });

  test('joined operation keeps the source durability provenance', () async {
    final id = _id('joined-provenance');
    final gate = Completer<Uint8List>();
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );
    final local = manager.readSessionArtifact(
      id: id,
      length: 3,
      loader: () => gate.future,
    );
    await Future<void>.delayed(Duration.zero);

    final lookup = ArtifactCacheLookup(
      id: id,
      entry: ArtifactCacheStreamEntry(
        length: 3,
        open: ({required int start, int? endExclusive}) async* {
          yield Uint8List.fromList(<int>[1, 2, 3]);
        },
        readAll: () => gate.future,
        fullReadIntegrity: ArtifactReadIntegrityBasis.crc32Verified,
      ),
      tier: ArtifactCacheTier.persistent,
    );
    final foreground = manager.readForegroundLookup(lookup);
    gate.complete(Uint8List.fromList(<int>[1, 2, 3]));

    final localRead = await local;
    final foregroundRead = await foreground;
    expect(localRead.durable, isFalse);
    expect(foregroundRead.durable, isFalse);
    expect(localRead.integrityBasis, ArtifactReadIntegrityBasis.sessionArtifact);
    expect(
      foregroundRead.integrityBasis,
      ArtifactReadIntegrityBasis.sessionArtifact,
      reason: 'a later durable join cannot relabel the source operation proof',
    );
    expect((await manager.lookup(id))?.durable, isFalse);
  });

  test('cancelling a joined read does not block its local-read owner', () async {
    final id = _id('cancel-join');
    final gate = Completer<void>();
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[1, 2, 3]),
    }, readGate: gate);
    final manager = ArtifactCacheManager(backend: backend);
    final first = manager.readForeground(id);
    await Future<void>.delayed(Duration.zero);
    final control = _TestTaskControl(priority: 1000);
    final second = manager.readForeground(id, control: control);

    await Future<void>.delayed(Duration.zero);
    control.cancel();
    await expectLater(
      second,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );

    gate.complete();
    expect((await first)?.bytes, <int>[1, 2, 3]);
    expect(backend.readAllCalls, 1);
  });

  test('final cancellation detaches an uncontrolled backend read', () async {
    final id = _id('cancel-uncontrolled');
    final gate = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{id: Uint8List.fromList(<int>[1, 2, 3])},
      readGate: gate,
    );
    final manager = ArtifactCacheManager(backend: backend);
    final control = _TestTaskControl(priority: 900);
    final first = manager.readForeground(id, control: control);

    await Future<void>.delayed(Duration.zero);
    expect(backend.readAllCalls, 1);
    control.cancel();
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

    // The first backend future is still blocked and cannot observe the
    // operation control. It must nevertheless no longer be joinable by a new
    // consumer.
    final second = manager.readForeground(id);
    await Future<void>.delayed(Duration.zero);
    expect(backend.readAllCalls, 2);

    gate.complete();
    expect((await second)?.bytes, <int>[1, 2, 3]);
  });

  test('invalidation cancels an in-flight read and blocks stale memory repopulation',
      () async {
    final id = _id('invalidate-in-flight');
    final gate = Completer<void>();
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[1, 2, 3]),
    }, readGate: gate);
    final manager = ArtifactCacheManager(backend: backend);
    final read = manager.readForeground(id);
    final readError = expectLater(
      read,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );

    await Future<void>.delayed(Duration.zero);
    await manager.invalidate(id);
    await readError;

    gate.complete();
    await Future<void>.delayed(Duration.zero);

    expect(backend.values[id], isNull);
    expect(manager.lookupMemory(id), isNull);
  });

  test('a stale invalid read cannot invalidate a replacement operation',
      () async {
    final id = _id('stale-invalid-read');
    final backend = _StaleInvalidReadBackend();
    final manager = ArtifactCacheManager(backend: backend);
    final first = manager.readForeground(id);
    final firstError = expectLater(
      first,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );

    await Future<void>.delayed(Duration.zero);
    await manager.invalidate(id);
    final second = manager.readForeground(id);
    backend.release();

    await firstError;
    expect((await second)?.bytes, <int>[4, 5, 6]);
    expect(backend.invalidateCalls, 1,
        reason: 'only the explicit invalidation may reach the backend');
  });

  test('memory retention cannot repopulate during invalidation', () async {
    final id = _id('remember-during-invalidation');
    final invalidationGate = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{id: Uint8List.fromList(<int>[1, 2, 3])},
      invalidateGate: invalidationGate,
    );
    final manager = ArtifactCacheManager(backend: backend);
    manager.remember(id: id, bytes: Uint8List.fromList(<int>[1, 2, 3]));

    final invalidation = manager.invalidate(id);
    await Future<void>.delayed(Duration.zero);
    manager.remember(id: id, bytes: Uint8List.fromList(<int>[9, 9, 9]));

    invalidationGate.complete();
    await invalidation;
    expect(manager.lookupMemory(id), isNull);
  });

  test('clearMemory invalidates generation-scoped late retention', () {
    final id = _id('clear-memory-generation');
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );
    const generation = 0;

    // A source read can retain bytes with the generation it captured before
    // the manager had any mutation entry for this identity.
    manager.remember(
      id: id,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      generation: generation,
    );
    manager.clearMemory();
    manager.remember(
      id: id,
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
      generation: generation,
    );

    expect(manager.lookupMemory(id), isNull);
  });

  test('clearMemory detaches an in-flight read before a new caller joins',
      () async {
    final id = _id('clear-memory-in-flight');
    final gate = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{id: Uint8List.fromList(<int>[1, 2, 3])},
      readGate: gate,
    );
    final manager = ArtifactCacheManager(backend: backend);
    final first = manager.readForeground(id);

    await Future<void>.delayed(Duration.zero);
    expect(backend.readAllCalls, 1);
    final firstError = expectLater(
      first,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );

    manager.clearMemory();
    await firstError;

    final second = manager.readForeground(id);
    await Future<void>.delayed(Duration.zero);
    expect(backend.readAllCalls, 2);

    gate.complete();
    expect((await second)?.bytes, <int>[1, 2, 3]);
  });

  test('cancelling an invalid-entry lookup does not strand invalidation wait',
      () async {
    final id = _id('cancel-invalid-entry');
    final invalidationGate = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{id: Uint8List(0)},
      invalidateGate: invalidationGate,
    );
    final manager = ArtifactCacheManager(backend: backend);
    final control = _TestTaskControl(priority: 900);
    final lookup = manager.lookup(id, control: control);

    await Future<void>.delayed(Duration.zero);
    control.cancel();
    await expectLater(
      lookup,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );

    invalidationGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(backend.values[id], isNull);
  });

  test('reads wait behind an in-flight invalidation before reopening the backend',
      () async {
    final id = _id('invalidate-barrier');
    final readGate = Completer<void>();
    final invalidationGate = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{id: Uint8List.fromList(<int>[1, 2, 3])},
      readGate: readGate,
      invalidateGate: invalidationGate,
    );
    final manager = ArtifactCacheManager(backend: backend);
    final first = manager.readForeground(id);
    final firstError = expectLater(
      first,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final invalidation = manager.invalidate(id);
    await Future<void>.delayed(Duration.zero);

    final second = manager.readForeground(id);
    await Future<void>.delayed(Duration.zero);
    expect(backend.openCalls, 1,
        reason: 'a new read must not reopen stale backend bytes');

    readGate.complete();
    await firstError;
    invalidationGate.complete();
    await invalidation;
    expect(await second, isNull);
    expect(backend.openCalls, 2,
        reason: 'the post-invalidation lookup may reopen only after the barrier');
  });

  test('cancelled collection closes an uncontrolled artifact stream', () async {
    final id = _id('cancel-collect');
    final cancelled = Completer<void>();
    final body = StreamController<List<int>>(
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );
    final lookup = ArtifactCacheLookup(
      id: id,
      entry: ArtifactCacheStreamEntry(
        length: 3,
        open: ({required int start, int? endExclusive}) => body.stream,
      ),
      tier: ArtifactCacheTier.persistent,
    );
    final control = _TestTaskControl(priority: 900);
    final read = manager.readForegroundLookup(lookup, control: control);

    await Future<void>.delayed(Duration.zero);
    control.cancel();

    await expectLater(
      read,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    await cancelled.future.timeout(const Duration(seconds: 1));
    await body.close();
  });

  test('controlled backend full reads observe the caller cancellation', () async {
    final id = _id('controlled-read');
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final cancelled = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{id: bytes},
      controlledRead: (control, value) async {
        await control.whenCancelled;
        cancelled.complete();
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'controlled test read cancelled',
        );
      },
    );
    final manager = ArtifactCacheManager(backend: backend);
    final control = _TestTaskControl(priority: 900);
    final read = manager.readForeground(id, control: control);

    await Future<void>.delayed(Duration.zero);
    control.cancel();

    await expectLater(
      read,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    await cancelled.future.timeout(const Duration(seconds: 1));
    expect(backend.controlledReadCalls, 1);
    expect(manager.memoryEntryCount, 0);
  });

  test('cancelling one joined read does not abort another consumer', () async {
    final id = _id('controlled-join');
    final bytes = Uint8List.fromList(<int>[7, 8, 9]);
    final gate = Completer<Uint8List>();
    final backend = _Backend(
      <DownloadId, Uint8List>{id: bytes},
      controlledRead: (_, __) => gate.future,
    );
    final manager = ArtifactCacheManager(backend: backend);
    final firstControl = _TestTaskControl(priority: 900);
    final first = manager.readForeground(id, control: firstControl);
    await Future<void>.delayed(Duration.zero);
    final second = manager.readForeground(id);
    await Future<void>.delayed(Duration.zero);

    firstControl.cancel();
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

    gate.complete(bytes);
    expect((await second)?.bytes, bytes);
    expect(backend.controlledReadCalls, 1);
  });

  test('evicts least-recently-used bytes within manager bounds', () async {
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(
      backend: backend,
      memoryMaxEntries: 2,
      memoryMaxBytes: 7,
    );
    final first = _id('first');
    final second = _id('second');
    final third = _id('third');
    manager.remember(id: first, bytes: Uint8List(3));
    manager.remember(id: second, bytes: Uint8List(3));
    expect(manager.lookupMemory(first, length: 3), isNotNull);
    manager.remember(id: third, bytes: Uint8List(4));

    expect(manager.lookupMemory(first, length: 3), isNotNull);
    expect(manager.lookupMemory(second, length: 3), isNull);
    expect(manager.lookupMemory(third, length: 4), isNotNull);
    expect(manager.memoryEntryCount, 2);
    expect(manager.memoryBytes, 7);
  });

  test('rejects changed advertised length without retaining bytes', () async {
    final id = _id('changed');
    final backend = _Backend(<DownloadId, Uint8List>{
      id: Uint8List(5),
    });
    final manager = ArtifactCacheManager(backend: backend);
    final lookup = ArtifactCacheLookup(
      id: id,
      entry: ArtifactCacheStreamEntry(
        length: 4,
        open: ({required int start, int? endExclusive}) async* {
          yield Uint8List(5);
        },
        readAll: () async => Uint8List(5),
      ),
      tier: ArtifactCacheTier.persistent,
    );

    await expectLater(manager.readForegroundLookup(lookup), throwsStateError);
    expect(manager.lookupMemory(id), isNull);
  });

  test('purges an empty memory/backend artifact instead of serving it',
      () async {
    final id = _id('empty');
    final backend = _InvalidatingBackend(<DownloadId, Uint8List>{
      id: Uint8List(0),
    });
    final manager = ArtifactCacheManager(backend: backend);
    manager.remember(id: id, bytes: Uint8List(0), durable: true);

    expect(manager.lookupMemory(id), isNull);
    expect(await manager.readForeground(id), isNull);
    expect(backend.invalidated, contains(id));
    expect(backend.values[id], isNull);
  });

  test('refuses to write an empty promoted artifact', () async {
    final id = _id('empty-store');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);

    await expectLater(
      manager.storePromotedArtifact(id: id, bytes: Uint8List(0)),
      throwsStateError,
    );
    expect(backend.values, isEmpty);
  });

  test('writes through the backend and updates the memory tier', () async {
    final id = _id('store');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    final bytes = Uint8List.fromList(<int>[7, 8, 9]);

    await manager.storePromotedArtifact(id: id, bytes: bytes);

    expect(backend.values[id], bytes);
    expect(manager.lookupMemory(id), bytes);
  });

  test('promoted store writes through backend and populates memory tier', () async {
    final id = _id('store-byte-ownership');
    final storeGate = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{},
      storeGate: storeGate,
    );
    final manager = ArtifactCacheManager(backend: backend);
    final bytes = Uint8List.fromList(<int>[7, 8, 9]);
    final store = manager.storePromotedArtifact(id: id, bytes: bytes);

    await Future<void>.delayed(Duration.zero);
    storeGate.complete();
    await store;

    expect(backend.values[id], <int>[7, 8, 9]);
    expect(manager.lookupMemory(id), <int>[7, 8, 9]);
  });

  test('reads do not serve stale memory while a promoted store is pending',
      () async {
    final id = _id('store-barrier');
    final backend = _Backend(
      <DownloadId, Uint8List>{id: Uint8List.fromList(<int>[1, 2, 3])},
      storeGate: Completer<void>(),
    );
    final manager = ArtifactCacheManager(backend: backend);
    manager.remember(id: id, bytes: Uint8List.fromList(<int>[1, 2, 3]));

    final store = manager.storePromotedArtifact(
      id: id,
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(manager.lookupMemory(id), isNull);

    final lookup = manager.lookup(id);
    await Future<void>.delayed(Duration.zero);
    expect(backend.openCalls, 0,
        reason: 'backend lookup must wait for the serialized store');

    backend.storeGate!.complete();
    await store;
    final resolved = await lookup;
    expect(resolved, isNotNull);
    expect((await manager.readForeground(id))?.bytes, <int>[4, 5, 6]);
  });

  test('generation-scoped invalidation never deletes a newer artifact',
      () async {
    final id = _id('generation-scoped-invalidate');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    final oldBytes = Uint8List.fromList(<int>[1, 2, 3]);
    final newBytes = Uint8List.fromList(<int>[4, 5, 6]);

    await manager.storePromotedArtifact(id: id, bytes: oldBytes);
    final rejected = manager.lookupMemoryWithAuthority(id)!;
    await manager.storePromotedArtifact(id: id, bytes: newBytes);

    expect(
      await manager.invalidateIfGeneration(
        id,
        expectedGeneration: rejected.generation,
      ),
      isFalse,
    );
    expect(backend.values[id], newBytes);
    final current = manager.lookupMemoryWithAuthority(id)!;
    expect(current.bytes, newBytes);
    expect(current.generation, isNot(rejected.generation));
  });

  test('session read reselects promoted bytes after generation handoff',
      () async {
    final id = _id('session-read-generation-handoff');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    final oldReadGate = Completer<Uint8List>();
    final promoted = Uint8List.fromList(<int>[4, 5, 6]);

    final read = manager.readSessionArtifact(
      id: id,
      length: promoted.lengthInBytes,
      loader: () => oldReadGate.future,
    );
    final readExpectation = expectLater(
      read,
      completion(
        isA<ArtifactCacheRead>()
            .having((value) => value.bytes, 'bytes', promoted)
            .having((value) => value.durable, 'durable', isTrue),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    await manager.storePromotedArtifact(id: id, bytes: promoted);
    await readExpectation;
    expect(backend.values[id], promoted);
  });

  test('session read does not retry cancellation without generation change',
      () async {
    final id = _id('session-read-source-cancel');
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );
    var loads = 0;

    await expectLater(
      manager.readSessionArtifact(
        id: id,
        length: 3,
        loader: () async {
          loads++;
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'source cancelled without cache authority change',
          );
        },
      ),
      throwsA(
        isA<Failure>()
            .having((failure) => failure.code, 'code', ErrorCode.cancelled)
            .having(
              (failure) => failure.message,
              'message',
              'source cancelled without cache authority change',
            ),
      ),
    );
    expect(loads, 1);
  });

  test('verified equivalence reuses a different exact URL artifact', () async {
    final oldId = _versionId('old', 'https://e-hentai.org/g/1/old/001.jpg');
    final newId = _versionId('new', 'https://e-hentai.org/g/2/new/001.jpg');
    final bytes = Uint8List.fromList(<int>[9, 8, 7, 6]);
    final backend = _Backend(<DownloadId, Uint8List>{oldId: bytes});
    final manager = ArtifactCacheManager(backend: backend);

    manager.linkEquivalent(first: newId, second: oldId);
    final lookup = await manager.lookup(newId);
    final read = await manager.readForegroundLookup(lookup!);

    expect(lookup.id, newId);
    expect(lookup.storageId, oldId);
    expect(read.bytes, bytes);
    expect(backend.openCalls, 2);
    expect(manager.equivalenceCount, 1);
  });

  test('verified equivalence observes artifacts promoted after registration',
      () async {
    final older = _id('older-equivalent');
    final newer = _id('newer-equivalent');
    final backend = _Backend(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);

    manager.linkEquivalent(first: older, second: newer);
    expect(manager.equivalenceCount, 1);
    expect(await manager.readForeground(older), isNull);
    expect(await manager.readForeground(newer), isNull);

    await manager.storePromotedArtifact(
      id: newer,
      bytes: Uint8List.fromList(<int>[4, 4, 4]),
    );

    final reused = await manager.lookup(older);
    expect(reused?.id, older);
    expect(reused?.storageId, newer);
    expect((await manager.readForeground(older))?.bytes, <int>[4, 4, 4]);
    await manager.storePromotedArtifact(
      id: older,
      bytes: Uint8List.fromList(<int>[8, 8, 8]),
    );
    expect((await manager.readForeground(older))?.bytes, <int>[8, 8, 8]);
    expect((await manager.readForeground(newer))?.bytes, <int>[4, 4, 4]);
  });

  test('verified equivalence does not satisfy exact backend ownership',
      () async {
    final older = _id('older-owner');
    final newer = _id('newer-owner');
    final backend = _Backend(<DownloadId, Uint8List>{
      newer: Uint8List.fromList(<int>[3, 3, 3]),
    });
    final manager = ArtifactCacheManager(backend: backend);
    manager.linkEquivalent(first: older, second: newer);

    expect(await manager.contains(id: older, expectedLength: 3), isTrue);
    expect(
      await manager.containsBackendExact(id: older, expectedLength: 3),
      isFalse,
    );
    expect(await manager.lookupAuthoritative(older), isNull);
    expect(backend.values[newer], <int>[3, 3, 3]);
  });

  test('verified equivalence stays direct and exact writes remain authoritative',
      () async {
    final first = _id('first-version');
    final second = _id('second-version');
    final third = _id('third-version');
    final backend = _Backend(<DownloadId, Uint8List>{
      first: Uint8List.fromList(<int>[1, 2, 3]),
    });
    final manager = ArtifactCacheManager(backend: backend);

    manager.linkEquivalent(first: first, second: second);
    manager.linkEquivalent(first: second, second: third);
    expect((await manager.readForeground(second))?.bytes, <int>[1, 2, 3]);
    expect(await manager.readForeground(third), isNull);

    await manager.storePromotedArtifact(
      id: second,
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
    );
    expect((await manager.readForeground(second))?.bytes, <int>[4, 5, 6]);
    expect((await manager.readForeground(first))?.bytes, <int>[1, 2, 3]);
  });

  test('invalidating one exact identity never deletes an equivalent artifact',
      () async {
    final oldId = _id('old-target');
    final newId = _id('new-equivalent');
    final backend = _InvalidatingBackend(<DownloadId, Uint8List>{
      oldId: Uint8List.fromList(<int>[3, 2, 1]),
    });
    final manager = ArtifactCacheManager(backend: backend);
    manager.linkEquivalent(first: newId, second: oldId);

    await manager.invalidate(newId);

    expect(backend.invalidated, contains(newId));
    expect(backend.invalidated, isNot(contains(oldId)));
    expect((await manager.readForeground(oldId))?.bytes, <int>[3, 2, 1]);
  });

  test('fresh-source recovery quarantines cache fallback until exact durable write',
      () async {
    final target = _id('presentation-recovery-target');
    final sibling = _id('presentation-recovery-sibling');
    final stale = Uint8List.fromList(<int>[7, 7, 7]);
    final fresh = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final backend = _Backend(<DownloadId, Uint8List>{sibling: stale});
    final manager = ArtifactCacheManager(backend: backend);
    manager.linkEquivalent(first: target, second: sibling);

    expect((await manager.readForeground(target))?.bytes, stale);
    final recoveryGroup =
        manager.beginFreshSourceRecovery(<DownloadId>[target]);

    expect(manager.requiresFreshSource(target), isTrue);
    expect(manager.directEquivalents(target), isEmpty);
    expect(manager.lookupMemoryWithAuthority(target), isNull);
    expect(await manager.lookup(target), isNull);
    expect(await manager.lookupAuthoritative(target), isNull);
    expect(
      await manager.containsBackendExact(id: target, expectedLength: stale.length),
      isFalse,
    );
    expect((await manager.readForeground(sibling))?.bytes, stale);

    // Simulate an old promoted handoff that started before physical reset. It
    // may write exact bytes, but an unarmed recovery must keep them quarantined.
    await manager.storePromotedArtifact(id: target, bytes: stale);
    expect(manager.requiresFreshSource(target), isTrue);
    expect(await manager.readForeground(target), isNull);

    manager.armFreshSourceRecovery(recoveryGroup);
    await manager.storePromotedArtifact(id: target, bytes: fresh);

    expect(manager.requiresFreshSource(target), isFalse);
    expect((await manager.readForeground(target))?.bytes, fresh);
    expect((await manager.readForeground(sibling))?.bytes, stale);
  });

  test('fresh-source recovery withdraws an equivalent read already in flight',
      () async {
    final target = _id('presentation-recovery-race-target');
    final sibling = _id('presentation-recovery-race-sibling');
    final stale = Uint8List.fromList(<int>[9, 8, 7]);
    final gate = Completer<void>();
    final backend = _Backend(
      <DownloadId, Uint8List>{sibling: stale},
      readGate: gate,
    );
    final manager = ArtifactCacheManager(backend: backend);
    manager.linkEquivalent(first: target, second: sibling);

    final pending = manager.readForeground(target);
    while (backend.readAllCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    manager.beginFreshSourceRecovery(<DownloadId>[target]);
    gate.complete();

    expect(await pending, isNull);
    expect(manager.requiresFreshSource(target), isTrue);
    expect((await manager.readForeground(sibling))?.bytes, stale);
  });

  test('lazy equivalent resolver participates only in fallback lookup', () async {
    final target = _id('lazy-target');
    final source = _id('lazy-source');
    final backend = _Backend(<DownloadId, Uint8List>{
      source: Uint8List.fromList(<int>[7, 8, 9]),
    });
    final manager = ArtifactCacheManager(backend: backend);

    manager.registerEquivalentResolver(
      key: 'chapter-a',
      resolver: (id) => id == target ? <DownloadId>[source] : const <DownloadId>[],
    );

    expect(manager.equivalenceCount, 0);
    expect(manager.equivalenceResolverCount, 1);
    expect(manager.directEquivalents(target), <DownloadId>[source]);
    expect((await manager.lookup(target))?.storageId, source);
    expect(await manager.lookupAuthoritative(target), isNull);

    await manager.storePromotedArtifact(
      id: target,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    expect((await manager.lookup(target))?.storageId, target);
    expect(backend.values[source], <int>[7, 8, 9]);
  });

  test('lazy equivalent resolver groups are bounded and replaceable', () {
    final first = _id('lazy-first');
    final second = _id('lazy-second');
    final source = _id('lazy-source');
    final manager = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
      equivalenceResolverMaxEntries: 1,
    );

    manager.registerEquivalentResolver(
      key: 'first',
      resolver: (id) => id == first ? <DownloadId>[source] : const <DownloadId>[],
    );
    manager.registerEquivalentResolver(
      key: 'second',
      resolver: (id) => id == second ? <DownloadId>[source] : const <DownloadId>[],
    );

    expect(manager.equivalenceResolverCount, 1);
    expect(manager.hasEquivalentResolver('first'), isFalse);
    expect(manager.hasEquivalentResolver('second'), isTrue);
    expect(manager.directEquivalents(first), isEmpty);
    expect(manager.directEquivalents(second), <DownloadId>[source]);
    manager.clearMemory();
    expect(manager.hasEquivalentResolver('second'), isFalse);
    expect(manager.equivalenceResolverCount, 0);
  });

  test('equivalence capacity evicts the oldest proof without moving artifacts',
      () async {
    final first = _id('first-proof');
    final second = _id('second-proof');
    final third = _id('third-proof');
    final backend = _Backend(<DownloadId, Uint8List>{
      first: Uint8List.fromList(<int>[1]),
      second: Uint8List.fromList(<int>[2]),
    });
    final manager = ArtifactCacheManager(
      backend: backend,
      equivalenceMaxEntries: 1,
    );

    manager.linkEquivalent(first: first, second: third);
    manager.linkEquivalent(first: second, second: third);

    expect(manager.directEquivalents(first), isEmpty);
    expect(manager.directEquivalents(second), contains(third));
    expect(backend.values[first], <int>[1]);
    expect(backend.values[second], <int>[2]);
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
      canonicalUri: Uri.parse('memory://$page'),
    );

DownloadId _versionId(String version, String uri) => DownloadId(
      content: ContentId(
        sourceId: 'venera:ehentai',
        comicId: 'gallery-$version',
        chapterId: 'chapter-$version',
        pageId: 'page-0',
      ),
      sourceRevision: version,
      canonicalUri: Uri.parse(uri),
    );

final class _TestTaskControl implements TaskControl {
  _TestTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();

  @override
  int priority;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class _Backend implements ArtifactCacheBackend {
  _Backend(
    this.values, {
    this.readGate,
    this.controlledRead,
    this.invalidateGate,
    this.storeGate,
    this.presentationOpen,
  });

  final Map<DownloadId, Uint8List> values;
  final Completer<void>? readGate;
  final Future<Uint8List> Function(TaskControl control, Uint8List bytes)?
      controlledRead;
  final Completer<void>? invalidateGate;
  final Completer<void>? storeGate;
  final Future<ArtifactCachePresentationFileLease?> Function(
    DownloadId id,
    Uint8List bytes,
  )? presentationOpen;
  int openCalls = 0;
  int readAllCalls = 0;
  int controlledReadCalls = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    openCalls++;
    final bytes = values[id];
    if (bytes == null) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.sublistView(
          bytes,
          start,
          endExclusive ?? bytes.lengthInBytes,
        );
      },
      readAll: () async {
        readAllCalls++;
        await readGate?.future;
        return bytes;
      },
      readAllControlled: controlledRead == null
          ? null
          : ({required TaskControl control}) {
              controlledReadCalls++;
              return controlledRead!(control, bytes);
            },
      openPresentationFile: presentationOpen == null
          ? null
          : () => presentationOpen!(id, bytes),
    );
  }


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    await storeGate?.future;
    values[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    await invalidateGate?.future;
    values.remove(id);
  }
}


final class _StaleInvalidReadBackend implements ArtifactCacheBackend {
  final Completer<void> _releaseGate = Completer<void>();
  int _openCalls = 0;
  int invalidateCalls = 0;

  void release() {
    if (!_releaseGate.isCompleted) _releaseGate.complete();
  }

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    _openCalls++;
    final result = _openCalls == 1
        ? Uint8List(0)
        : Uint8List.fromList(<int>[4, 5, 6]);
    return ArtifactCacheStreamEntry(
      length: 3,
      open: ({required int start, int? endExclusive}) async* {
        yield result;
      },
      readAll: () async {
        await _releaseGate.future;
        return result;
      },
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    invalidateCalls++;
  }
}

final class _InvalidatingBackend extends _Backend
    implements ArtifactCacheBackend {
  _InvalidatingBackend(super.values);

  final List<DownloadId> invalidated = <DownloadId>[];

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    invalidated.add(id);
    values.remove(id);
  }


}
