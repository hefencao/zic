import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

void main() {
  test(
    'encoded presentation file is a non-WebP durable capability',
    () async {
      final uri = Uri.parse('https://example.invalid/presentation-file.jpg');
      final chapter = _chapter(uri: uri);
      final backend = _PresentationFileBackend();
      final transferRuntime = CompositionDownloadTransferRuntime(
        artifactCacheManager: ArtifactCacheManager(backend: backend),
        partialDownloadStore: null,
        net: NetLane(maxActive: 1),
      );
      final reader = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
      ).withTransferRuntime(transferRuntime).create(
        chapter: chapter,
        sessionId: 'presentation-file-capability',
      );

      try {
        final lease = await reader.openEncodedPresentationFile(
          chapter.pages.single,
          MediaLoadToken(),
        );
        expect(lease, isNotNull);
        expect(lease!.width, 1200);
        expect(lease.height, 1800);
        expect(backend.opens, 1);
        await lease.release();
        expect(backend.releases, 1);
      } finally {
        await reader.dispose().timeout(const Duration(seconds: 5));
        await transferRuntime.dispose().timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'WebP and GIF never enter encoded presentation file fallback',
    () async {
      for (final hint in <ContentKindHint>[
        ContentKindHint.webp,
        ContentKindHint.gif,
      ]) {
        final uri = Uri.parse('https://example.invalid/file-${hint.name}');
        final chapter = _chapter(uri: uri, contentKindHint: hint);
        final backend = _PresentationFileBackend();
        final transferRuntime = CompositionDownloadTransferRuntime(
          artifactCacheManager: ArtifactCacheManager(backend: backend),
          partialDownloadStore: null,
          net: NetLane(maxActive: 1),
        );
        final reader = PipelineReaderSessionFactory(
          mediaRuntimeFactory: const _FreshFactory(),
          pageDownloadLane: NetLane(maxActive: 5),
        ).withTransferRuntime(transferRuntime).create(
          chapter: chapter,
          sessionId: 'presentation-file-excluded-${hint.name}',
        );
        try {
          expect(
            await reader.openEncodedPresentationFile(
              chapter.pages.single,
              MediaLoadToken(),
            ),
            isNull,
          );
          expect(backend.opens, 0);
        } finally {
          await reader.dispose().timeout(const Duration(seconds: 5));
          await transferRuntime.dispose().timeout(const Duration(seconds: 5));
        }
      }
    },
  );

  test(
    'Reader cache miss hands a long source open to the proven lower deadline',
    () async {
      final uri = Uri.parse('https://example.invalid/reader-slow-open.jpg');
      final chapter = _chapter(uri: uri);
      final id = readerPageDownloadId(chapter, chapter.pages.single);
      final cache = ArtifactCacheManager(backend: const _Backend());
      final transferRuntime = CompositionDownloadTransferRuntime(
        artifactCacheManager: cache,
        partialDownloadStore: null,
        net: NetLane(maxActive: 1),
        readStallTimeout: const Duration(milliseconds: 80),
      );
      var opens = 0;
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
      ).withTransferRuntime(transferRuntime).withLoaderSources(
        <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'slow-r1',
            selfBoundedOpen: true,
            openControlledResponse: ({range, validators, control}) async {
              opens++;
              await Future<void>.delayed(const Duration(milliseconds: 180));
              control?.throwIfCancelled();
              return ByteResponse(
                bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
                statusCode: 200,
                rangeStart: 0,
                totalLength: 3,
              );
            },
          ),
        },
      );
      final reader = factory.create(
        chapter: chapter,
        sessionId: 'reader-cache-phase-handoff',
      );

      try {
        reader.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
        reader.accept(_observation(reader.sessionId, chapter));

        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (transferRuntime.registry.find(id)?.state !=
            DownloadState.promoted) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Reader physical transfer did not promote after slow source open');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(opens, 1);
        expect(transferRuntime.registry.find(id)?.committedLength, 3);
      } finally {
        await reader.dispose().timeout(const Duration(seconds: 5));
        await transferRuntime.dispose().timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'late presentation failure cannot invalidate a newer cache generation',
    () async {
      final uri = Uri.parse('https://example.invalid/stale-cache-failure.jpg');
      final chapter = _chapter(uri: uri);
      final asset = chapter.pages.single;
      final id = readerPageDownloadId(chapter, asset);
      final oldBytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0x01]);
      final newBytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0x02]);
      final cache = ArtifactCacheManager(backend: const _Backend());
      cache.remember(id: id, bytes: oldBytes, durable: true);
      final transferRuntime = CompositionDownloadTransferRuntime(
        artifactCacheManager: cache,
        partialDownloadStore: null,
        net: NetLane(maxActive: 1),
      );
      var sourceOpens = 0;
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
      ).withTransferRuntime(transferRuntime).withLoaderSources(
        <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'stale-r1',
            openControlledResponse: ({range, validators, control}) async {
              sourceOpens++;
              return ByteResponse(
                bytes: Stream<List<int>>.value(newBytes),
                statusCode: 200,
                rangeStart: 0,
                totalLength: newBytes.lengthInBytes,
              );
            },
          ),
        },
      );
      final reader = factory.create(
        chapter: chapter,
        sessionId: 'presentation-stale-generation',
      );

      try {
        final first = await reader
            .loadBytes(asset, MediaLoadToken())
            .timeout(const Duration(seconds: 2));
        expect(first, oldBytes);

        await cache.storePromotedArtifact(id: id, bytes: newBytes);
        expect(
          await reader.recoverPresentationFailure(
            asset,
            StateError('late rejection from old generation'),
          ),
          isTrue,
        );

        final reloaded = await reader
            .loadBytes(asset, MediaLoadToken())
            .timeout(const Duration(seconds: 2));
        expect(reloaded, newBytes);
        expect(sourceOpens, 0);
      } finally {
        await reader.dispose().timeout(const Duration(seconds: 5));
        await transferRuntime.dispose().timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'presentation rejection of a cached image cancels hydration and reopens source once',
    () async {
      final uri = Uri.parse('https://example.invalid/recover-old-cache.jpg');
      final chapter = _chapter(uri: uri);
      final asset = chapter.pages.single;
      final id = readerPageDownloadId(chapter, asset);
      final cachedImage = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final store = _RejectedCachedImageStore(id: id, bytes: cachedImage);
      final cache = ArtifactCacheManager(backend: store);
      final transferRuntime = CompositionDownloadTransferRuntime(
        artifactCacheManager: cache,
        partialDownloadStore: store,
        net: NetLane(maxActive: 1),
      );
      const fresh = <int>[0xff, 0xd8, 0xff, 0xd9];
      var sourceOpens = 0;
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
      ).withTransferRuntime(transferRuntime).withLoaderSources(
        <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'fresh-r1',
            openControlledResponse: ({range, validators, control}) async {
              sourceOpens++;
              return ByteResponse(
                bytes: Stream<List<int>>.value(fresh),
                statusCode: 200,
                rangeStart: 0,
                totalLength: fresh.length,
              );
            },
          ),
        },
      );
      final reader = factory.create(
        chapter: chapter,
        sessionId: 'presentation-old-cache-recovery',
      );

      try {
        reader.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
        reader.accept(_observation(reader.sessionId, chapter));
        await store.partialOpened.future.timeout(const Duration(seconds: 2));

        final cached = await reader
            .loadBytes(asset, MediaLoadToken())
            .timeout(const Duration(seconds: 2));
        expect(cached, cachedImage);
        expect(transferRuntime.registry.find(id)?.state,
            DownloadState.receiving);

        expect(
          await reader.recoverPresentationFailure(
            asset,
            StateError('decoder rejected cached image'),
          ),
          isTrue,
        );
        expect(store.invalidations, 1);
        expect(
          await reader.recoverPresentationFailure(
            asset,
            const FormatException('must not auto-loop'),
          ),
          isFalse,
        );

        final recovered = await reader
            .loadBytes(asset, MediaLoadToken())
            .timeout(const Duration(seconds: 5));
        expect(recovered, Uint8List.fromList(fresh));
        expect(sourceOpens, 1);
        expect(transferRuntime.registry.find(id)?.state,
            DownloadState.promoted);
      } finally {
        await reader.dispose().timeout(const Duration(seconds: 5));
        await transferRuntime.dispose().timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'manual force reload destroys the physical final and bypasses equivalent reuse',
    () async {
      final uri = Uri.parse('https://example.invalid/recover-promoted-cache.jpg');
      final chapter = _chapter(uri: uri);
      final asset = chapter.pages.single;
      final id = readerPageDownloadId(chapter, asset);
      final cachedImage = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final siblingId = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'older-comic',
          chapterId: 'chapter',
          pageId: 'page-0',
        ),
        sourceRevision: 'older-r1',
        canonicalUri: Uri.parse(
          'https://example.invalid/recover-promoted-cache-older.jpg',
        ),
      );
      final partialCompletionGate = Completer<void>();
      final store = _RejectedCachedImageStore(
        id: id,
        bytes: cachedImage,
        equivalentId: siblingId,
        completePartial: true,
        partialCompletionGate: partialCompletionGate,
      );
      final cache = ArtifactCacheManager(backend: store);
      cache.linkEquivalent(first: id, second: siblingId);
      final transferRuntime = CompositionDownloadTransferRuntime(
        artifactCacheManager: cache,
        partialDownloadStore: store,
        net: NetLane(maxActive: 1),
      );
      const fresh = <int>[0xff, 0xd8, 0xff, 0xd9];
      var sourceOpens = 0;
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
      ).withTransferRuntime(transferRuntime).withLoaderSources(
        <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'fresh-r1',
            openControlledResponse: ({range, validators, control}) async {
              sourceOpens++;
              return ByteResponse(
                bytes: Stream<List<int>>.value(fresh),
                statusCode: 200,
                rangeStart: 0,
                totalLength: fresh.length,
              );
            },
          ),
        },
      );
      final reader = factory.create(
        chapter: chapter,
        sessionId: 'presentation-promoted-cache-recovery',
      );

      try {
        reader.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
        reader.accept(_observation(reader.sessionId, chapter));
        await store.partialOpened.future.timeout(const Duration(seconds: 2));

        // Presentation reads the durable cache while local hydration is still
        // receiving. This is the real-device ordering: the semantic failure
        // arrives only after that same body has also become a promoted physical
        // final.
        final cached = await reader
            .loadBytes(asset, MediaLoadToken())
            .timeout(const Duration(seconds: 2));
        expect(cached, cachedImage);
        partialCompletionGate.complete();
        await _waitForCondition(
          () => transferRuntime.registry.find(id)?.state == DownloadState.promoted,
        );
        final beforeRecovery = transferRuntime.registry.find(id)!;
        expect(beforeRecovery.committedLength, cachedImage.lengthInBytes);
        expect(sourceOpens, 0);

        expect(
          await reader.forceReloadPresentation(asset),
          isTrue,
        );
        await _waitForCondition(() => sourceOpens == 1);
        final recovered = await reader
            .loadBytes(asset, MediaLoadToken())
            .timeout(const Duration(seconds: 5));
        expect(recovered, Uint8List.fromList(fresh));
        expect(sourceOpens, 1);
        expect(store.invalidations, 1);
        await _waitForCondition(
          () => transferRuntime.registry.find(id)?.state == DownloadState.promoted,
        );
        final freshSession = transferRuntime.registry.find(id)!;
        expect(freshSession.committedLength, fresh.length);
        expect(cache.requiresFreshSource(id), isTrue);
        expect(
          await transferRuntime.artifactCacheHandoff!.settleAutomatic(freshSession),
          isTrue,
        );
        expect(cache.requiresFreshSource(id), isFalse);
        expect((await cache.readForeground(siblingId))?.bytes, cachedImage);
      } finally {
        await reader.dispose().timeout(const Duration(seconds: 5));
        await transferRuntime.dispose().timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'canonical force reload preserves pinned exact download and refreshes one physical epoch',
    () async {
      final uri = Uri.parse('https://example.invalid/canonical-pinned-reload.jpg');
      final chapter = _chapter(uri: uri);
      final asset = chapter.pages.single;
      final id = readerPageDownloadId(chapter, asset);
      final cachedImage = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final physicalId = PhysicalMediaId.canonical('canonical-pinned-page');
      final store = _RejectedCachedImageStore(
        id: id,
        bytes: cachedImage,
        completePartial: true,
        pinnedExact: true,
        physicalId: physicalId,
      );
      final cache = ArtifactCacheManager(backend: store);
      final transferRuntime = CompositionDownloadTransferRuntime(
        artifactCacheManager: cache,
        partialDownloadStore: store,
        net: NetLane(maxActive: 1),
      );
      transferRuntime.registry.bindPhysicalMedia(
        id: id,
        physicalId: physicalId,
      );
      const fresh = <int>[0xff, 0xd8, 0xff, 0xd9];
      var sourceOpens = 0;
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
      ).withTransferRuntime(transferRuntime).withLoaderSources(
        <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'fresh-r1',
            openControlledResponse: ({range, validators, control}) async {
              sourceOpens++;
              return ByteResponse(
                bytes: Stream<List<int>>.value(fresh),
                statusCode: 200,
                rangeStart: 0,
                totalLength: fresh.length,
              );
            },
          ),
        },
      );
      final reader = factory.create(
        chapter: chapter,
        sessionId: 'presentation-canonical-pinned-reload',
      );

      try {
        reader.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
        reader.accept(_observation(reader.sessionId, chapter));
        await _waitForCondition(
          () => transferRuntime.registry.find(id)?.state == DownloadState.promoted,
        );
        expect(
          await reader.loadBytes(asset, MediaLoadToken()).timeout(
                const Duration(seconds: 5),
              ),
          cachedImage,
        );
        final physicalBindsBeforeReload = store.physicalBinds;

        expect(
          await reader
              .forceReloadPresentation(asset)
              .timeout(const Duration(seconds: 5)),
          isTrue,
        );
        await _waitForCondition(() => sourceOpens == 1);
        expect(
          await reader.loadBytes(asset, MediaLoadToken()).timeout(
                const Duration(seconds: 5),
              ),
          Uint8List.fromList(fresh),
        );
        expect(store.invalidations, 0);
        expect(store.physicalInvalidations, 1);
        expect(store.physicalPartialInvalidations, 1);
        final preservedExact = await store.openArtifactStream(id);
        expect(preservedExact, isNotNull);
        expect(await preservedExact!.readAll!(), cachedImage);

        await _waitForCondition(
          () => transferRuntime.registry.find(id)?.state == DownloadState.promoted,
        );
        final freshSession = transferRuntime.registry.find(id)!;
        expect(
          await transferRuntime.artifactCacheHandoff!
              .settleAutomatic(freshSession)
              .timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(cache.requiresFreshSource(id), isFalse);
        expect(store.stores, 0);
        expect(store.physicalBinds, physicalBindsBeforeReload);
      } finally {
        await reader.dispose().timeout(const Duration(seconds: 5));
        await transferRuntime.dispose().timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'force reload also protects requested pinned exact when presentation authority differs',
    () async {
      final uri = Uri.parse('https://example.invalid/requested-pinned-fallback.jpg');
      final chapter = _chapter(uri: uri);
      final asset = chapter.pages.single;
      final id = readerPageDownloadId(chapter, asset);
      final siblingId = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'older-comic',
          chapterId: 'chapter',
          pageId: 'page-0',
        ),
        sourceRevision: 'older-r1',
        canonicalUri: Uri.parse(
          'https://example.invalid/requested-pinned-fallback-old.jpg',
        ),
      );
      final cachedImage = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final store = _RejectedCachedImageStore(
        id: id,
        equivalentId: siblingId,
        bytes: cachedImage,
        pinnedExact: true,
      );
      final cache = ArtifactCacheManager(backend: store);
      final runtime = CompositionDownloadTransferRuntime(
        artifactCacheManager: cache,
        partialDownloadStore: store,
        net: NetLane(maxActive: 1),
      );
      try {
        expect(
          await runtime.recoverPresentationArtifact(
            id,
            reason: 'requested-pinned-different-storage-authority',
            userInitiated: true,
            rejectedStorageId: siblingId,
            rejectedGeneration: cache.generationFor(siblingId),
          ),
          isTrue,
        );
        expect(store.retentionQueries, <DownloadId>[siblingId, id]);
        expect(store.invalidations, 0);
        final preserved = await store.openArtifactStream(id);
        expect(preserved, isNotNull);
        expect(await preserved!.readAll!(), cachedImage);
      } finally {
        await runtime.dispose().timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'presentation loadBytes reads immutable local sources before promotion',
    () async {
      const payload = <int>[7, 8, 9];
      var directOpens = 0;

      final uri = Uri.parse('file:///zic-presentation-direct/page-0.jpg');
      final chapter = _chapter(uri: uri);
      final id = readerPageDownloadId(chapter, chapter.pages.single);
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
        artifactCacheManager: ArtifactCacheManager(backend: const _Backend()),
      ).withLoaderSources(<Uri, LoaderTransportSource>{
        id.canonicalUri: LoaderTransportSource(
          revision: 'local-r1',
          openControlledResponse: ({range, validators, control}) async {
            // The physical transfer owns the network-ranked CancelToken;
            // presentation now supplies its own cancellation-only control.
            if (control != null && control.priority >= 0) {
              return ByteResponse(
                bytes: _neverEndingBody(),
                statusCode: 200,
                rangeStart: 0,
                totalLength: payload.length,
                validators: const Validators(etag: '"local-r1-3"'),
              );
            }
            directOpens++;
            return ByteResponse(
              bytes: Stream<List<int>>.value(Uint8List.fromList(payload)),
              statusCode: 200,
              rangeStart: 0,
              totalLength: payload.length,
              validators: const Validators(etag: '"local-r1-3"'),
            );
          },
        ),
      });
      final reader = factory.create(
        chapter: chapter,
        sessionId: 'presentation-direct-reader',
      );

      try {
        reader.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
        reader.accept(_observation(reader.sessionId, chapter));

        final token = MediaLoadToken();
        final bytes = await reader
            .loadBytes(chapter.pages.single, token)
            .timeout(const Duration(seconds: 5));

        expect(bytes, Uint8List.fromList(payload));
        expect(directOpens, 1, reason: 'presentation must open its own '
            'immutable source read instead of waiting for the gated transfer');

        final warmBytes = await reader
            .loadBytes(chapter.pages.single, MediaLoadToken())
            .timeout(const Duration(seconds: 5));
        expect(warmBytes, Uint8List.fromList(payload));
        expect(directOpens, 1, reason: 'the validated direct read must feed '
            'the presentation memory tier for immediate remounts');
      } finally {
        // Detaching Reader demand cancels the gated physical attempt; the
        // never-ending body only ends through that cancellation.
        await reader.dispose().timeout(const Duration(seconds: 10));
        await factory
            .disposeRetainedSessions()
            .timeout(const Duration(seconds: 10));
        await factory
            .disposeTransferRuntimes()
            .timeout(const Duration(seconds: 10));
      }
    });
}

Future<void> _waitForCondition(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Stream<List<int>> _neverEndingBody() async* {
  // The gated transfer attempt never receives a byte; it exits only when its
  // consumer cancels the response subscription.
  await Completer<void>().future;
}

ReaderObs _observation(String sessionId, ChapterManifest chapter) => ReaderObs(
      sessionId: sessionId,
      currentIndex: 0,
      stableIndex: 0,
      interaction: Interaction.idle,
      logicalPosition: 0,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 0,
        assetKey: chapter.pages.single.assetKey,
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026),
      monotonicMicros: 1,
    );

ChapterManifest _chapter({
  required Uri uri,
  ContentKindHint contentKindHint = ContentKindHint.jpeg,
}) => ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-0',
          chapterId: 'chapter',
          index: 0,
          uri: uri,
          contentKindHint: contentKindHint,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

final class _PresentationFileBackend implements ArtifactCacheBackend {
  int opens = 0;
  int releases = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    opens++;
    return ArtifactCacheStreamEntry(
      length: 3,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.fromList(const <int>[1, 2, 3]);
      },
      openPresentationFile: () async => ArtifactCachePresentationFileLease(
        path: '/proc/self/fd/41',
        length: 3,
        width: 1200,
        height: 1800,
        release: () async => releases++,
      ),
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _RejectedCachedImageStore
    implements
        ArtifactCacheBackend,
        ArtifactCacheRetentionQuery,
        PhysicalArtifactCacheBackend,
        PhysicalPartialDownloadStore,
        PartialDownloadStore {
  _RejectedCachedImageStore({
    required this.id,
    required this.bytes,
    this.equivalentId,
    this.completePartial = false,
    this.partialCompletionGate,
    this.pinnedExact = false,
    this.physicalId,
  });

  final DownloadId id;
  final Uint8List bytes;
  final DownloadId? equivalentId;
  final bool completePartial;
  final Completer<void>? partialCompletionGate;
  final bool pinnedExact;
  final PhysicalMediaId? physicalId;
  final Completer<void> partialOpened = Completer<void>();
  bool invalidated = false;
  bool physicalInvalidated = false;
  int invalidations = 0;
  int physicalInvalidations = 0;
  int physicalPartialInvalidations = 0;
  int physicalBinds = 0;
  int stores = 0;
  final List<DownloadId> retentionQueries = <DownloadId>[];

  bool _canRead(DownloadId candidate) =>
      (candidate == id && !invalidated) || candidate == equivalentId;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId candidate) async {
    if (!_canRead(candidate)) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        final end = endExclusive ?? bytes.lengthInBytes;
        yield Uint8List.sublistView(bytes, start, end);
      },
      readAll: () async => bytes,
      fullReadIntegrity: ArtifactReadIntegrityBasis.crc32Verified,
    );
  }

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId candidate) async {
    if (!_canRead(candidate)) return null;
    return PartialDownloadEntry(
      length: bytes.lengthInBytes,
      validators: const Validators(etag: '"old-cache"'),
      totalLength: bytes.lengthInBytes,
      open: ({required int start}) {
        if (completePartial) {
          final gate = partialCompletionGate;
          if (gate == null) {
            if (!partialOpened.isCompleted) partialOpened.complete();
            return Stream<List<int>>.value(
              Uint8List.sublistView(bytes, start),
            );
          }
          return (() async* {
            final split = bytes.lengthInBytes ~/ 2;
            if (!partialOpened.isCompleted) partialOpened.complete();
            if (start < split) {
              yield Uint8List.sublistView(bytes, start, split);
            }
            await gate.future;
            final suffixStart = start > split ? start : split;
            if (suffixStart < bytes.lengthInBytes) {
              yield Uint8List.sublistView(bytes, suffixStart);
            }
          })();
        }
        late final StreamController<List<int>> controller;
        controller = StreamController<List<int>>(
          onListen: () {
            if (!partialOpened.isCompleted) partialOpened.complete();
            final split = bytes.lengthInBytes ~/ 2;
            if (start < split) {
              controller.add(Uint8List.sublistView(bytes, start, split));
            }
            // Keep local hydration in-flight until recovery cancels this stream.
          },
        );
        return controller.stream;
      },
      exactDurableFinal: completePartial,
    );
  }

  @override
  Future<bool> isPinnedExactArtifact(DownloadId candidate) async {
    retentionQueries.add(candidate);
    return pinnedExact && candidate == id && !invalidated;
  }

  @override
  Future<ArtifactCacheStreamEntry?> openPhysicalArtifact(
    PhysicalMediaId candidate,
  ) async {
    if (candidate != physicalId || physicalInvalidated) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        final end = endExclusive ?? bytes.lengthInBytes;
        yield Uint8List.sublistView(bytes, start, end);
      },
      readAll: () async => bytes,
      fullReadIntegrity: ArtifactReadIntegrityBasis.crc32Verified,
    );
  }

  @override
  Future<bool> bindPhysicalArtifact({
    required PhysicalMediaId physicalId,
    required DownloadId sourceId,
  }) async {
    if (this.physicalId != physicalId) return false;
    physicalBinds++;
    physicalInvalidated = false;
    return true;
  }

  @override
  Future<void> invalidatePhysicalArtifact(PhysicalMediaId candidate) async {
    if (candidate != physicalId) return;
    physicalInvalidated = true;
    physicalInvalidations++;
  }

  @override
  Future<PartialDownloadEntry?> openPhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId requestId,
  }) async => null;

  @override
  Future<void> storePhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId providerHint,
    required PartialDownloadEntry entry,
    bool preferDirectStaging = false,
  }) async {}

  @override
  Future<void> invalidatePhysicalPartialDownload(
    PhysicalMediaId candidate,
  ) async {
    if (candidate == physicalId) physicalPartialInvalidations++;
  }

  @override
  Future<void> invalidateArtifact(DownloadId candidate) async {
    if (candidate != id) return;
    invalidated = true;
    invalidations++;
  }

  @override
  Future<void> invalidatePartialDownload(DownloadId candidate) async {
    if (candidate != id) return;
    invalidated = true;
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) async {}

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    stores++;
  }
}

final class _Backend implements ArtifactCacheBackend {
  const _Backend();

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async =>
      null;

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _FreshFactory implements PipelineMediaRuntimeFactory {
  const _FreshFactory();

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) =>
      _Runtime();
}

final class _Runtime implements PipelineMediaRuntime {
  @override
  SourceFactory get sources => _SourceFactory();

  @override
  CursorFactory get cursors => const _CursorFactory();

  @override
  FrameUploader get uploader => const _Uploader();

  @override
  PipelineOutputProjector get outputs => const _Projector();

  @override
  PipelineFrameScheduler get frameScheduler => const _TestFrameScheduler();

  @override
  RendererKind get renderer => RendererKind.flutterImage;

  @override
  Future<void> close() async {}
}

final class _SourceFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _Source(epoch);
}

final class _Source implements EncodedSource {
  _Source(this.epoch);

  @override
  int epoch;
  @override
  int length = 0;
  @override
  bool sealed = false;
  @override
  SourceKind kind = SourceKind.unknown;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    length += bytes.length;
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    length = 0;
    sealed = false;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) {
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}

final class _CursorFactory implements CursorFactory {
  const _CursorFactory();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) =>
      throw UnsupportedError('not used');
}

final class _Uploader implements FrameUploader {
  const _Uploader();

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) =>
      throw UnsupportedError('not used');

  @override
  void release(DecodeId id) {}
}

final class _Projector implements PipelineOutputProjector {
  const _Projector();

  @override
  PipelinePageSurface project(OutputFrame frame) => const _Surface();
}

final class _Surface implements PipelinePageSurface {
  const _Surface();

  @override
  int get width => 1;

  @override
  int get height => 1;

  @override
  Object get presentationIdentity => this;

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.low,
  }) =>
      SizedBox(key: key, width: 1, height: 1);
}

final class _TestFrameScheduler implements PipelineFrameScheduler {
  const _TestFrameScheduler();

  @override
  bool get inPersistentCallbacks => false;

  @override
  bool get isIdle => true;

  @override
  bool get hasScheduledFrame => false;

  @override
  void afterFrame(void Function() callback) => scheduleMicrotask(callback);

  @override
  void scheduleIdle(void Function() callback) => scheduleMicrotask(callback);

  @override
  void requestFrame() {}
}
