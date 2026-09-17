import 'dart:typed_data';

import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/home_service_cache_binding.dart';

void main() {
  test('owned bootstrap cache derives from the chapter service and closes',
      () async {
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    addTearDown(downloads.close);
    final binding = HomeServiceCacheBinding.create(
      chapterDownloads: downloads,
      downloadComposition: null,
    );

    expect(binding.ownsCoordinator, isTrue);
    expect(binding.readerArtifactCache, isNotNull);
    expect(binding.coordinator.artifacts, same(downloads));

    await binding.closeIfOwned();
    expect(
      () => binding.coordinator.responses.drainPersistence(),
      throwsA(isA<StateError>()),
    );
  });

  test('supplied coordinator remains externally owned', () async {
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final supplied = ResourceCacheCoordinator();
    addTearDown(downloads.close);
    addTearDown(supplied.close);
    final binding = HomeServiceCacheBinding.create(
      chapterDownloads: downloads,
      downloadComposition: null,
      suppliedCoordinator: supplied,
    );

    expect(binding.ownsCoordinator, isFalse);
    expect(binding.coordinator, same(supplied));

    await binding.closeIfOwned();
    await supplied.responses.drainPersistence();
  });

  test('superseded owned cache does not close shared response authority',
      () async {
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final sharedResponses = ResourceCacheManager();
    final previousCoordinator = ResourceCacheCoordinator(
      responses: sharedResponses,
    );
    final nextCoordinator = ResourceCacheCoordinator(
      responses: sharedResponses,
    );
    addTearDown(downloads.close);
    addTearDown(nextCoordinator.close);
    final previous = HomeServiceCacheBinding.create(
      chapterDownloads: downloads,
      downloadComposition: null,
      suppliedCoordinator: previousCoordinator,
    );
    final next = HomeServiceCacheBinding.create(
      chapterDownloads: downloads,
      downloadComposition: null,
      suppliedCoordinator: nextCoordinator,
    );

    await previous.closeIfSupersededBy(next);
    await sharedResponses.drainPersistence();
  });
}
