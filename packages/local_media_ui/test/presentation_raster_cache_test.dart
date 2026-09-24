import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
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

      final usage = owner.inspectPresentationRasters();
      expect(usage.entries, 1);
      expect(invalidated, <Object>[speculativeIdentity]);
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

      expect(owner.inspectPresentationRasters().entries, 1);
      expect(invalidated, contains(firstIdentity));
      expect(invalidated, isNot(contains(secondIdentity)));
    },
  );
}
