import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

void main() {
  testWidgets(
    'mounted external static reloads when Pipeline presentation generation changes',
    (tester) async {
      pipelinePresentationRasterCache.clearPresentationRasters();
      addTearDown(() {
        pipelinePresentationRasterCache.clearPresentationRasters();
        while (SchedulerBinding.instance.handleEventLoopCallback()) {}
      });
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final uri = Uri.parse('asset:///generation-static.png');
      final chapter = _chapter(uri);
      final session = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _RuntimeFactory(),
        pageDownloadLane: NetLane(maxActive: 2),
        loaderSources: <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'generation-static-r1',
            loadBytes: () async => bytes,
          ),
        },
      ).create(
        chapter: chapter,
        sessionId: 'external-generation-widget-test',
      );
      addTearDown(session.dispose);
      session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));

      final asset = chapter.pages.single;
      final output = session.pageOutput(asset);
      final stream = session.pageStream(asset);
      var loads = 0;
      final image = PickedImage(
        file: XFile('generation-static.png'),
        format: LocalImageFormat.png,
        displayName: 'generation-static.png',
        sourceId: uri.toString(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 360,
            child: LocalImagePlayer(
              image: image,
              tokenBytesLoader: (_, token) async {
                token.throwIfCancelled();
                loads++;
                return Uint8List.fromList(bytes);
              },
              pageStream: stream,
              pageOutput: output,
            ),
          ),
        ),
      );
      session.accept(_observation(chapter));

      await _pumpUntil(tester, () => loads >= 1);
      await _pumpUntil(
        tester,
        () => output.externalPresentationReady &&
            !output.externalPresentationRequested,
      );
      expect(
        loads,
        1,
        reason:
            'requested -> ready is one presentation-state handoff; first-frame '
            'completion must not transiently revoke and reload the healthy raster',
      );
      final firstIdentity = output.externalPresentationCacheIdentity;
      expect(firstIdentity, isNotNull);

      session.updateDecodeTarget(
        DecodeTarget(physicalWidth: 640, physicalHeight: 960),
      );
      session.accept(_observation(chapter));

      await _pumpUntil(tester, () => loads >= 2);
      expect(
        identical(firstIdentity, output.externalPresentationCacheIdentity),
        isFalse,
        reason:
            'the same mounted page output must expose a new exact presentation generation after DecodeId rebind',
      );
      expect(
        loads,
        2,
        reason:
            'widget lifetime must not suppress the new Pipeline presentation grant',
      );
      // Managed raster maintenance is deliberately queued at scheduler-idle so
      // a same-generation deadline promotion can revoke a speculative eviction
      // intent (ADR 0327). Retire this test's mounted consumer and drain that
      // owner queue before flutter_test checks for leaked scheduler timers.
      await tester.pumpWidget(const SizedBox.shrink());
      pipelinePresentationRasterCache.clearPresentationRasters();
      for (var turn = 0; turn < 2; turn++) {
        while (SchedulerBinding.instance.handleEventLoopCallback()) {}
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );

  testWidgets(
    'detached resident raster mounts exactly and same generation regrants after eviction',
    (tester) async {
      pipelinePresentationRasterCache.clearPresentationRasters();
      addTearDown(() {
        pipelinePresentationRasterCache.clearPresentationRasters();
        while (SchedulerBinding.instance.handleEventLoopCallback()) {}
      });
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final chapter = _chapterWithPages(12);
      final session = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _RuntimeFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
        externalPresentationPrewarmer:
            prewarmPipelineExternalStaticPresentation,
        presentationCacheAuthority: pipelinePresentationRasterCache,
        loaderSources: <Uri, LoaderTransportSource>{
          for (final page in chapter.pages)
            page.uri: LoaderTransportSource(
              revision: 'resident-static-r1',
              loadBytes: () async => bytes,
            ),
        },
      ).create(
        chapter: chapter,
        sessionId: 'resident-detached-mounted-widget-test',
      );
      addTearDown(session.dispose);
      session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));

      final asset = chapter.pages[2];
      final output = session.pageOutput(asset);
      final stream = session.pageStream(asset);
      session.accept(_observationAt(chapter, 0, 1));
      await _pumpUntil(tester, () => output.externalPresentationReady);
      expect(output.externalPresentationCacheIdentity, isNotNull);
      expect(
        pipelinePresentationRasterCache.inspectPresentationRasters().entries,
        greaterThan(0),
      );
      final presentationIdentity =
          output.externalPresentationCacheIdentity!;
      final residentBeforeMount = pipelinePresentationRasterCache
          .residentProviderForIdentity(presentationIdentity);
      expect(residentBeforeMount, isNotNull);
      final residentKeyBeforeMount = await residentBeforeMount!.obtainKey(
        ImageConfiguration.empty,
      );

      var presentationFileOpens = 0;
      var byteLoads = 0;
      final image = PickedImage(
        file: XFile('resident-static.png'),
        format: LocalImageFormat.png,
        displayName: 'resident-static.png',
        sourceId: asset.uri.toString(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 360,
            child: LocalImagePlayer(
              image: image,
              presentationFileLoader: (token) async {
                token.throwIfCancelled();
                presentationFileOpens++;
                return null;
              },
              tokenBytesLoader: (_, token) async {
                token.throwIfCancelled();
                byteLoads++;
                return Uint8List.fromList(bytes);
              },
              pageStream: stream,
              pageOutput: output,
            ),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(imageFolderFlutterPreviewKey).evaluate().isNotEmpty,
      );

      expect(
        presentationFileOpens,
        0,
        reason:
            'the managed raster owner already has the exact presentation '
            'identity, so mounted binding must not reopen encoded storage',
      );
      expect(byteLoads, 0);
      final residentAfterMount = pipelinePresentationRasterCache
          .residentProviderForIdentity(presentationIdentity);
      expect(residentAfterMount, isNotNull);
      expect(
        await residentAfterMount!.obtainKey(ImageConfiguration.empty),
        residentKeyBeforeMount,
        reason:
            'mounting an exact detached raster must not wrap it in another '
            'managed/resize key and silently move cache ownership',
      );

      session.accept(_observationAt(chapter, 11, 2));
      await _pumpUntil(
        tester,
        () =>
            !output.externalPresentationRequested &&
            !output.externalPresentationReady,
      );
      await tester.pump();
      expect(find.byKey(imageFolderFlutterPreviewKey), findsNothing);
      pipelinePresentationRasterCache.clearPresentationRasters();

      session.accept(_observationAt(chapter, 2, 3));
      await _pumpUntil(
        tester,
        () => find.byKey(imageFolderFlutterPreviewKey).evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => output.externalPresentationReady &&
            !output.externalPresentationRequested,
      );
      expect(
        identical(
          presentationIdentity,
          output.externalPresentationCacheIdentity,
        ),
        isTrue,
        reason:
            'ordinary raster eviction and later regrant must keep the '
            'immutable presentation generation stable',
      );
      expect(
        output.externalPresentationReady,
        isTrue,
        reason:
            'same-generation regrant must receive a fresh mounted first-frame '
            'acknowledgement instead of being suppressed by widget lifetime',
      );
      expect(
        presentationFileOpens + byteLoads,
        greaterThan(0),
        reason:
            'after the detached raster residency is actually gone, the '
            'mounted consumer must re-enter encoded presentation instead of '
            'reusing a stale resident-only completer',
      );

      await session.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      pipelinePresentationRasterCache.clearPresentationRasters();
      for (var turn = 0; turn < 2; turn++) {
        while (SchedulerBinding.instance.handleEventLoopCallback()) {}
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );

  testWidgets(
    'mounted external static relinquishes raster across a presentation demand gap',
    (tester) async {
      pipelinePresentationRasterCache.clearPresentationRasters();
      addTearDown(pipelinePresentationRasterCache.clearPresentationRasters);
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final chapter = _chapterWithPages(12);
      final session = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _RuntimeFactory(),
        pageDownloadLane: NetLane(maxActive: 5),
        presentationCacheAuthority: pipelinePresentationRasterCache,
        loaderSources: <Uri, LoaderTransportSource>{
          for (final page in chapter.pages)
            page.uri: LoaderTransportSource(
              revision: 'managed-static-r1',
              loadBytes: () async => bytes,
            ),
        },
      ).create(
        chapter: chapter,
        sessionId: 'external-demand-gap-widget-test',
      );
      addTearDown(session.dispose);
      session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));

      final asset = chapter.pages.first;
      final output = session.pageOutput(asset);
      final stream = session.pageStream(asset);
      var loads = 0;
      final image = PickedImage(
        file: XFile('managed-static.png'),
        format: LocalImageFormat.png,
        displayName: 'managed-static.png',
        sourceId: asset.uri.toString(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 360,
            child: LocalImagePlayer(
              image: image,
              tokenBytesLoader: (_, token) async {
                token.throwIfCancelled();
                loads++;
                return Uint8List.fromList(bytes);
              },
              pageStream: stream,
              pageOutput: output,
            ),
          ),
        ),
      );

      session.accept(_observationAt(chapter, 0, 1));
      await _pumpUntil(
        tester,
        () => find.byKey(imageFolderFlutterPreviewKey).evaluate().isNotEmpty,
      );
      final identity = output.externalPresentationCacheIdentity;
      expect(identity, isNotNull);
      expect(loads, 1);

      session.accept(_observationAt(chapter, 10, 2));
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      // Keep these expectations split: if the first fails, the bug is still in
      // Pipeline demand/output retirement; if only the second fails, the
      // mounted presentation consumer is retaining raster ownership.
      expect(
        identical(identity, output.externalPresentationCacheIdentity),
        isTrue,
        reason:
            'ordinary demand loss revokes residency permission without rotating immutable presentation generation',
      );
      expect(output.externalPresentationRequested, isFalse);
      expect(output.externalPresentationReady, isFalse);
      expect(find.byKey(imageFolderFlutterPreviewKey), findsNothing);
      expect(find.byKey(imagePageLoadingIndicatorKey), findsOneWidget,
          reason:
              'a composed page outside Pipeline presentation demand must release its concrete raster consumer');

      pipelinePresentationRasterCache.invalidatePresentationIdentity(identity!);
      expect(
        pipelinePresentationRasterCache.inspectPresentationRasters().entries,
        0,
        reason:
            'after the mounted consumer relinquishes its ImageInfo, the cache owner can fully retire the residency entry',
      );

      session.accept(_observationAt(chapter, 0, 3));
      await _pumpUntil(
        tester,
        () => find.byKey(imageFolderFlutterPreviewKey).evaluate().isNotEmpty,
      );
      expect(
        identical(identity, output.externalPresentationCacheIdentity),
        isTrue,
        reason:
            'ordinary residency/demand loss must not rotate immutable presentation generation',
      );
      expect(
        loads,
        2,
        reason:
            'once raster residency is explicitly invalidated, the widget must '
            'not act as a second encoded/raster cache; the same presentation '
            'generation re-enters its authoritative encoded loader once',
      );
      await session.dispose();
      await tester.pump(const Duration(milliseconds: 150));
    },
  );

  testWidgets(
    'managed raster decode failure preserves the mounted error authority',
    (tester) async {
      pipelinePresentationRasterCache.clearPresentationRasters();
      addTearDown(() {
        pipelinePresentationRasterCache.clearPresentationRasters();
        while (SchedulerBinding.instance.handleEventLoopCallback()) {}
      });
      final valid = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final corrupt = Uint8List.fromList(valid.sublist(0, 33));
      final uri = Uri.parse('asset:///managed-corrupt.png');
      final chapter = _chapter(uri);
      final asset = chapter.pages.single;
      final authority = PipelinePresentationArtifactAuthority(
        storageId: DownloadId(
          content: const ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: 'page-0',
          ),
          sourceRevision: 'r1',
          canonicalUri: uri,
        ),
        generation: 7,
      );
      final session = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _RuntimeFactory(),
        pageDownloadLane: NetLane(maxActive: 2),
        presentationCacheAuthority: pipelinePresentationRasterCache,
        loaderSources: <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'managed-corrupt-r1',
            loadBytes: () async => valid,
          ),
        },
      ).create(
        chapter: chapter,
        sessionId: 'managed-corrupt-error-channel-test',
      );
      addTearDown(session.dispose);
      session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
      final output = session.pageOutput(asset);
      final stream = session.pageStream(asset);
      var recoveries = 0;
      PipelinePresentationArtifactAuthority? rejectedAuthority;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 360,
            child: LocalImagePlayer(
              image: PickedImage(
                file: XFile('managed-corrupt.png'),
                format: LocalImageFormat.png,
                displayName: 'managed-corrupt.png',
                sourceId: uri.toString(),
              ),
              presentationBytesLoader: (_, token) async {
                token.throwIfCancelled();
                return PipelinePresentationBytes(
                  bytes: corrupt,
                  authority: authority,
                );
              },
              onRecoverPresentationFailure: (_, rejected) async {
                recoveries++;
                rejectedAuthority = rejected;
                return false;
              },
              pageStream: stream,
              pageOutput: output,
            ),
          ),
        ),
      );
      session.accept(_observation(chapter));

      await _pumpUntil(tester, () => recoveries == 1);
      await _pumpUntil(
        tester,
        () => find.byKey(imageFolderPreviewErrorKey).evaluate().isNotEmpty,
      );
      expect(identical(rejectedAuthority, authority), isTrue);
      expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
      expect(
        output.externalPresentationRequested,
        isTrue,
        reason:
            'decode failure is delivered through the current presentation '
            'attempt before Pipeline treats the raster as ordinary residency loss',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      pipelinePresentationRasterCache.clearPresentationRasters();
      for (var turn = 0; turn < 2; turn++) {
        while (SchedulerBinding.instance.handleEventLoopCallback()) {}
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );

  testWidgets(
    'new presentation grant supersedes an older in-flight recovery',
    (tester) async {
      pipelinePresentationRasterCache.clearPresentationRasters();
      addTearDown(() {
        pipelinePresentationRasterCache.clearPresentationRasters();
        while (SchedulerBinding.instance.handleEventLoopCallback()) {}
      });
      final valid = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final corrupt = Uint8List.fromList(valid.sublist(0, 33));
      final uri = Uri.parse('asset:///recovery-supersede.png');
      final chapter = _chapter(uri);
      final asset = chapter.pages.single;
      final session = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _RuntimeFactory(),
        pageDownloadLane: NetLane(maxActive: 2),
        presentationCacheAuthority: pipelinePresentationRasterCache,
        loaderSources: <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'recovery-supersede-r1',
            loadBytes: () async => valid,
          ),
        },
      ).create(
        chapter: chapter,
        sessionId: 'recovery-supersede-widget-test',
      );
      addTearDown(session.dispose);
      session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
      final output = session.pageOutput(asset);
      final stream = session.pageStream(asset);
      final recovery = Completer<bool>();
      var recoveries = 0;
      var loads = 0;
      var fresh = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 360,
            child: LocalImagePlayer(
              image: PickedImage(
                file: XFile('recovery-supersede.png'),
                format: LocalImageFormat.png,
                displayName: 'recovery-supersede.png',
                sourceId: uri.toString(),
              ),
              presentationBytesLoader: (_, token) async {
                token.throwIfCancelled();
                loads++;
                return PipelinePresentationBytes(
                  bytes: fresh ? valid : corrupt,
                );
              },
              onRecoverPresentationFailure: (_, __) {
                recoveries++;
                return recovery.future;
              },
              pageStream: stream,
              pageOutput: output,
            ),
          ),
        ),
      );
      session.accept(_observation(chapter));
      await _pumpUntil(tester, () => recoveries == 1);
      final firstIdentity = output.externalPresentationCacheIdentity;

      fresh = true;
      session.updateDecodeTarget(
        DecodeTarget(physicalWidth: 640, physicalHeight: 960),
      );
      session.accept(_observation(chapter));
      await _pumpUntil(tester, () => loads >= 2);
      await _pumpUntil(
        tester,
        () => output.externalPresentationReady &&
            !output.externalPresentationRequested,
      );
      expect(
        identical(firstIdentity, output.externalPresentationCacheIdentity),
        isFalse,
      );

      recovery.complete(false);
      await tester.pumpAndSettle();
      expect(find.byKey(imageFolderPreviewErrorKey), findsNothing);
      expect(output.externalPresentationReady, isTrue);
      expect(loads, 2);
    },
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var attempt = 0; attempt < 200 && !predicate(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(predicate(), isTrue);
}

ChapterManifest _chapter(Uri uri) => ChapterManifest(
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
          width: 1,
          height: 1,
          contentKindHint: ContentKindHint.unknown,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

ChapterManifest _chapterWithPages(int count) => ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: count,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        count,
        (index) => PageAsset(
          pageId: 'managed-page-$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('asset:///managed-page-$index.png'),
          width: 1,
          height: 1,
          contentKindHint: ContentKindHint.png,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );

ReaderObs _observation(ChapterManifest chapter) => ReaderObs(
      sessionId: 'external-generation-widget-test',
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
      direction: chapter.readingDirection,
      timestamp: DateTime.utc(2026),
      monotonicMicros: 1,
    );

ReaderObs _observationAt(
  ChapterManifest chapter,
  int index,
  int monotonicMicros,
) =>
    ReaderObs(
      sessionId: 'external-demand-gap-widget-test',
      currentIndex: index,
      stableIndex: index,
      interaction: Interaction.idle,
      logicalPosition: index.toDouble(),
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: index,
        assetKey: chapter.pages[index].assetKey,
        fraction: 1,
      ),
      direction: chapter.readingDirection,
      timestamp: DateTime.utc(2026),
      monotonicMicros: monotonicMicros,
    );

final class _RuntimeFactory implements PipelineMediaRuntimeFactory {
  const _RuntimeFactory();

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) =>
      const _Runtime();
}

final class _Runtime implements PipelineMediaRuntime {
  const _Runtime();

  @override
  SourceFactory get sources => const _SourceFactory();

  @override
  CursorFactory get cursors => const _CursorFactory();

  @override
  FrameUploader get uploader => const _Uploader();

  @override
  PipelineOutputProjector get outputs => const _Projector();

  @override
  PipelineFrameScheduler get frameScheduler => const _FrameScheduler();

  @override
  RendererKind get renderer => RendererKind.flutterImage;

  @override
  Future<void> close() async {}
}

final class _SourceFactory implements SourceFactory {
  const _SourceFactory();

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
    kind = SourceKind.unknown;
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
      throw UnsupportedError('fallback static does not use a native cursor');
}

final class _Uploader implements FrameUploader {
  const _Uploader();

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) =>
      throw UnsupportedError('fallback static does not use native upload');

  @override
  void release(DecodeId id) {}
}

final class _Projector implements PipelineOutputProjector {
  const _Projector();

  @override
  PipelinePageSurface project(OutputFrame frame) =>
      throw UnsupportedError('fallback static does not use native output');
}

final class _FrameScheduler implements PipelineFrameScheduler {
  const _FrameScheduler();

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
