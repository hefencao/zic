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
    'presentation loadBytes reads immutable local sources before promotion',
    () async {
      const payload = <int>[7, 8, 9];
      var directOpens = 0;

      final uri = Uri.parse('file:///zic-presentation-direct/page-0.jpg');
      final chapter = _chapter(uri: uri);
      final id = readerPageDownloadId(chapter, chapter.pages.single);
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
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

ChapterManifest _chapter({required Uri uri}) => ChapterManifest(
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
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

final class _RejectedCachedImageStore
    implements ArtifactCacheBackend, PartialDownloadStore {
  _RejectedCachedImageStore({required this.id, required this.bytes});

  final DownloadId id;
  final Uint8List bytes;
  final Completer<void> partialOpened = Completer<void>();
  bool invalidated = false;
  int invalidations = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId candidate) async {
    if (candidate != id || invalidated) return null;
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
    if (candidate != id || invalidated) return null;
    return PartialDownloadEntry(
      length: bytes.lengthInBytes,
      validators: const Validators(etag: '"old-cache"'),
      totalLength: bytes.lengthInBytes,
      open: ({required int start}) {
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
    );
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
  }) async {}
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
