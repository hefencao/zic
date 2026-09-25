import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

Uint8List _tinyPng() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Future<void> _resolveFirstFrame(ImageProvider<Object> provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final completed = Completer<void>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (image, _) {
      image.dispose();
      stream.removeListener(listener);
      if (!completed.isCompleted) completed.complete();
    },
    onError: (Object error, StackTrace? stackTrace) {
      stream.removeListener(listener);
      if (!completed.isCompleted) {
        completed.completeError(error, stackTrace);
      }
    },
  );
  stream.addListener(listener);
  await completed.future;
}

void _drainSchedulerTasks() {
  while (SchedulerBinding.instance.handleEventLoopCallback()) {}
}

void main() {
  testWidgets(
    'presentation raster owner trims speculative entries by managed claim',
    (tester) async {
      final imageCache = PaintingBinding.instance.imageCache;
      final oldMaximumSize = imageCache.maximumSize;
      final oldMaximumSizeBytes = imageCache.maximumSizeBytes;
      final owner = PipelinePresentationRasterCache(
        maximumBytes: 1024 * 1024,
        maximumEntries: 1,
      );
      addTearDown(() {
        owner.clearPresentationRasters();
        imageCache.maximumSize = oldMaximumSize;
        imageCache.maximumSizeBytes = oldMaximumSizeBytes;
        imageCache.clearLiveImages();
      });
      final protectedIdentity = Object();
      final speculativeIdentity = Object();
      final invalidated = <Object>[];
      owner.addInvalidationListener(invalidated.add);
      owner.updatePresentationClaim(
        protectedIdentity,
        PipelinePresentationCacheClaim.protected,
      );
      owner.updatePresentationClaim(
        speculativeIdentity,
        PipelinePresentationCacheClaim.speculative,
      );

      ImageProvider<Object> managed(Object identity) => owner.providerFor(
        provider: encodedResourceImageProvider(
          MemoryEncodedResourceSource(_tinyPng(), cacheIdentity: identity),
        ),
        presentationIdentity: identity,
      );

      await tester.runAsync(
        () => _resolveFirstFrame(managed(protectedIdentity)),
      );
      await tester.runAsync(
        () => _resolveFirstFrame(managed(speculativeIdentity)),
      );
      await tester.pump();
      _drainSchedulerTasks();

      final usage = owner.inspectPresentationRasters();
      expect(usage.entries, 1);
      expect(invalidated, <Object>[speculativeIdentity]);
      expect(owner.allowsPresentationWarm(speculativeIdentity), isFalse,
          reason:
              'the budget owner that evicted speculative residency must also own backpressure against immediate speculative re-admission');
      owner.updatePresentationClaim(
        speculativeIdentity,
        PipelinePresentationCacheClaim.deadline,
      );
      expect(owner.allowsPresentationWarm(speculativeIdentity), isTrue,
          reason:
              'deadline promotion must clear the cache-owner admission denial without a Pipeline-side tombstone');
      expect(
        imageCache.maximumSize,
        owner.maximumEntries - usage.entries,
        reason:
            'managed Reader rasters and generic Flutter images must share one entry envelope',
      );
      expect(
        imageCache.maximumSizeBytes,
        owner.maximumBytes - usage.bytes,
        reason:
            'managed Reader raster bytes must be reserved out of the generic Flutter ImageCache budget',
      );
    },
  );

  testWidgets(
    'deadline promotion rescues a deferred speculative budget eviction',
    (tester) async {
      final imageCache = PaintingBinding.instance.imageCache;
      final oldMaximumSize = imageCache.maximumSize;
      final oldMaximumSizeBytes = imageCache.maximumSizeBytes;
      final owner = PipelinePresentationRasterCache(
        maximumBytes: 1024 * 1024,
        maximumEntries: 1,
      );
      addTearDown(() {
        owner.clearPresentationRasters();
        imageCache.maximumSize = oldMaximumSize;
        imageCache.maximumSizeBytes = oldMaximumSizeBytes;
        imageCache.clearLiveImages();
      });
      final rescuedIdentity = Object();
      final protectedIdentity = Object();
      final invalidated = <Object>[];
      owner.addInvalidationListener(invalidated.add);
      owner.updatePresentationClaim(
        rescuedIdentity,
        PipelinePresentationCacheClaim.speculative,
      );
      owner.updatePresentationClaim(
        protectedIdentity,
        PipelinePresentationCacheClaim.protected,
      );

      ImageProvider<Object> managed(Object identity) => owner.providerFor(
        provider: encodedResourceImageProvider(
          MemoryEncodedResourceSource(_tinyPng(), cacheIdentity: identity),
        ),
        presentationIdentity: identity,
      );

      await tester.runAsync(() => _resolveFirstFrame(managed(rescuedIdentity)));
      await tester.pump();
      _drainSchedulerTasks();
      expect(owner.inspectPresentationRasters().entries, 1);

      await tester.runAsync(() => _resolveFirstFrame(managed(protectedIdentity)));
      expect(owner.inspectPresentationRasters().entries, 1,
          reason:
              'budget selection may withdraw speculative authority before idle physical cleanup');
      expect(invalidated, isEmpty,
          reason:
              'budget invalidation is deferred with the physical eviction so a role promotion can still rescue it');

      owner.updatePresentationClaim(
        rescuedIdentity,
        PipelinePresentationCacheClaim.deadline,
      );
      expect(owner.inspectPresentationRasters().entries, 2,
          reason:
              'a deadline promotion must reclaim the still-live raster instead of decoding the same page again');

      await tester.pump();
      _drainSchedulerTasks();
      expect(invalidated, isEmpty,
          reason:
              'rescued deadline residency must not emit the stale speculative eviction');
      expect(owner.inspectPresentationRasters().entries, 2);
    },
  );

  testWidgets(
    'clear drops residency but preserves demand claims and speculative backpressure',
    (tester) async {
      final imageCache = PaintingBinding.instance.imageCache;
      final oldMaximumSize = imageCache.maximumSize;
      final oldMaximumSizeBytes = imageCache.maximumSizeBytes;
      final owner = PipelinePresentationRasterCache(
        maximumBytes: 2 * 1024 * 1024,
        maximumEntries: 2,
      );
      addTearDown(() {
        owner.clearPresentationRasters();
        imageCache.maximumSize = oldMaximumSize;
        imageCache.maximumSizeBytes = oldMaximumSizeBytes;
        imageCache.clearLiveImages();
      });
      final protectedIdentity = Object();
      final speculativeIdentity = Object();
      owner.updatePresentationClaim(
        protectedIdentity,
        PipelinePresentationCacheClaim.protected,
      );
      owner.updatePresentationClaim(
        speculativeIdentity,
        PipelinePresentationCacheClaim.speculative,
      );
      ImageProvider<Object> managed(Object identity) => owner.providerFor(
        provider: encodedResourceImageProvider(
          MemoryEncodedResourceSource(_tinyPng(), cacheIdentity: identity),
        ),
        presentationIdentity: identity,
      );
      await tester.runAsync(
        () => _resolveFirstFrame(managed(protectedIdentity)),
      );
      await tester.runAsync(
        () => _resolveFirstFrame(managed(speculativeIdentity)),
      );
      expect(owner.inspectPresentationRasters().entries, 2);

      owner.clearPresentationRasters();

      expect(owner.inspectPresentationRasters().entries, 0);
      expect(owner.allowsPresentationWarm(protectedIdentity), isTrue,
          reason:
              'memory-pressure/cache clear removes residency, not the current protected demand claim');
      expect(owner.allowsPresentationWarm(speculativeIdentity), isFalse,
          reason:
              'a cleared speculative raster must not immediately refill from idle warm');
      owner.updatePresentationClaim(
        speculativeIdentity,
        PipelinePresentationCacheClaim.deadline,
      );
      expect(owner.allowsPresentationWarm(speculativeIdentity), isTrue);
    },
  );

  testWidgets(
    'managed Reader raster bypasses Flutter live-completer residency',
    (tester) async {
      final imageCache = PaintingBinding.instance.imageCache;
      final oldMaximumSize = imageCache.maximumSize;
      final oldMaximumSizeBytes = imageCache.maximumSizeBytes;
      pipelinePresentationRasterCache.clearPresentationRasters();
      addTearDown(() {
        pipelinePresentationRasterCache.clearPresentationRasters();
        imageCache.maximumSize = oldMaximumSize;
        imageCache.maximumSizeBytes = oldMaximumSizeBytes;
        imageCache.clearLiveImages();
      });
      final identity = Object();
      pipelinePresentationRasterCache.updatePresentationClaim(
        identity,
        PipelinePresentationCacheClaim.protected,
      );
      final baseProvider = encodedResourceImageProvider(
        MemoryEncodedResourceSource(_tinyPng(), cacheIdentity: identity),
      );
      final providerKey = await baseProvider.obtainKey(ImageConfiguration.empty);
      final prewarmed = pipelinePresentationRasterCache.providerFor(
        provider: baseProvider,
        presentationIdentity: identity,
      );
      await tester.runAsync(() => _resolveFirstFrame(prewarmed));
      var frameReady = false;

      await tester.pumpWidget(
        TickerMode(
          enabled: false,
          child: SizedBox(
            width: 32,
            height: 32,
            child: MediaRasterImage(
              image: baseProvider,
              dimensions: null,
              fit: BoxFit.contain,
              presentationIdentity: identity,
              frameBuilder: (context, child, frame, synchronouslyLoaded) {
                if (frame != null || synchronouslyLoaded) frameReady = true;
                return child;
              },
            ),
          ),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!frameReady) {
        if (DateTime.now().isAfter(deadline)) {
          fail('managed raster never produced a first frame');
        }
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      _drainSchedulerTasks();

      final status = imageCache.statusForKey(providerKey);
      expect(status.live, isFalse,
          reason:
              'managed static presentation must not leave Flutter Image/TickerMode as a second live-completer owner');
      expect(status.keepAlive, isFalse,
          reason:
              'the generic Flutter ImageCache keepAlive must be removed after managed admission');
      expect(
        pipelinePresentationRasterCache.inspectPresentationRasters().entries,
        1,
      );
    },
  );

  testWidgets(
    'releasing a deadline claim makes the same raster LRU-reclaimable',
    (tester) async {
      final imageCache = PaintingBinding.instance.imageCache;
      final oldMaximumSize = imageCache.maximumSize;
      final oldMaximumSizeBytes = imageCache.maximumSizeBytes;
      final owner = PipelinePresentationRasterCache(
        maximumBytes: 1024 * 1024,
        maximumEntries: 1,
      );
      addTearDown(() {
        owner.clearPresentationRasters();
        imageCache.maximumSize = oldMaximumSize;
        imageCache.maximumSizeBytes = oldMaximumSizeBytes;
        imageCache.clearLiveImages();
      });
      final firstIdentity = Object();
      final secondIdentity = Object();
      final invalidated = <Object>[];
      owner.addInvalidationListener(invalidated.add);
      owner.updatePresentationClaim(
        firstIdentity,
        PipelinePresentationCacheClaim.deadline,
      );

      ImageProvider<Object> managed(Object identity) => owner.providerFor(
        provider: encodedResourceImageProvider(
          MemoryEncodedResourceSource(_tinyPng(), cacheIdentity: identity),
        ),
        presentationIdentity: identity,
      );

      await tester.runAsync(() => _resolveFirstFrame(managed(firstIdentity)));
      owner.releasePresentationClaim(firstIdentity);
      await tester.runAsync(() => _resolveFirstFrame(managed(secondIdentity)));
      await tester.pump();
      _drainSchedulerTasks();

      expect(owner.inspectPresentationRasters().entries, 1);
      expect(invalidated, contains(firstIdentity));
      expect(invalidated, isNot(contains(secondIdentity)));
    },
  );

  testWidgets(
    'raster invalidation withdraws authority before frame-deferred cleanup',
    (tester) async {
      final imageCache = _RecordingImageCache();
      final owner = PipelinePresentationRasterCache(
        maximumBytes: 1024 * 1024,
        maximumEntries: 4,
        imageCache: imageCache,
      );
      final identity = Object();
      final invalidated = <Object>[];
      owner.addInvalidationListener(invalidated.add);
      owner.updatePresentationClaim(
        identity,
        PipelinePresentationCacheClaim.speculative,
      );
      final provider = owner.providerFor(
        provider: encodedResourceImageProvider(
          MemoryEncodedResourceSource(_tinyPng(), cacheIdentity: identity),
        ),
        presentationIdentity: identity,
      );
      await tester.runAsync(() => _resolveFirstFrame(provider));
      await tester.pump();
      expect(owner.inspectPresentationRasters().entries, 1);
      final evictionsBefore = imageCache.evictions;

      tester.binding.scheduleFrame();
      owner.invalidatePresentationIdentity(identity);

      expect(owner.inspectPresentationRasters().entries, 0);
      expect(invalidated, <Object>[identity]);
      expect(
        imageCache.evictions,
        evictionsBefore,
        reason: 'physical Flutter-cache cleanup must not run before the queued frame',
      );

      await tester.pump();
      expect(imageCache.evictions, evictionsBefore + 1);
    },
  );
}

final class _RecordingImageCache extends ImageCache {
  int evictions = 0;

  @override
  bool evict(Object key, {bool includeLive = true}) {
    evictions++;
    return super.evict(key, includeLive: includeLive);
  }
}
