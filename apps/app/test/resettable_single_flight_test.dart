import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/resettable_single_flight.dart';

void main() {
  test('single-flight coalesces only until the current result settles',
      () async {
    final flight = ResettableSingleFlight<Object?>();
    final firstResult = Completer<Object?>();
    var calls = 0;

    final first = flight.run(() {
      calls++;
      return firstResult.future;
    });
    final joined = flight.run(() {
      calls++;
      return Object();
    });

    expect(identical(first, joined), isTrue);
    expect(calls, 1);
    firstResult.complete(null);
    expect(await first, isNull);
    expect(flight.active, isNull);

    final replacement = Object();
    expect(await flight.run(() => replacement), same(replacement));
    expect(calls, 1);

    await expectLater(
      flight.run(() => throw StateError('first open failed')),
      throwsStateError,
    );
    expect(flight.active, isNull);
    expect(await flight.run(() => replacement), same(replacement));
  });

  test('deferred capability handoff preserves bootstrap services', () async {
    final library = MemoryImportedLibraryStore();
    final cache = ResourceCacheCoordinator();
    addTearDown(cache.close);
    final handoff = HomeServiceHandoff()
      ..setBootstrapLibrary(library)
      ..setBootstrapCache(cache);
    Future<Null> pluginLoader() async => null;
    Future<void> platformLoader() async {}
    var notifications = 0;
    handoff.addListener(() => notifications++);

    handoff.updateDeferredCapabilities(
      externalPlugins: null,
      externalPluginLoader: pluginLoader,
      platformEnvironmentLoader: platformLoader,
      storageRoot: '/fixture/zic',
    );

    expect(handoff.libraryStore, same(library));
    expect(handoff.cacheCoordinator, same(cache));
    expect(handoff.externalPluginLoader, same(pluginLoader));
    expect(handoff.storageRoot, '/fixture/zic');
    expect(notifications, 1);

    handoff.updateDeferredCapabilities(
      externalPlugins: null,
      externalPluginLoader: pluginLoader,
      platformEnvironmentLoader: platformLoader,
      storageRoot: '/fixture/zic',
    );
    expect(notifications, 1);
  });
}
