import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:zic/home_external_source_lifecycle.dart';

void main() {
  test('controller loader is single-flight and adopted once', () async {
    final root = await Directory.systemTemp.createTemp('zic-external-lifecycle-');
    addTearDown(() => root.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      root.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    var loaderCalls = 0;
    final lifecycle = HomeExternalSourceLifecycle(
      loaderProvider: () => () async {
        loaderCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return controller;
      },
      sourceAvailable: (_) => false,
      isDeferredSource: (_) => true,
      refreshProjection: (_) async {},
    );
    addTearDown(lifecycle.close);

    final results = await Future.wait(<Future<ExternalPluginController?>>[
      lifecycle.ensureController(),
      lifecycle.ensureController(),
      lifecycle.ensureController(),
    ]);

    expect(loaderCalls, 1);
    expect(results, everyElement(same(controller)));
    expect(lifecycle.activeController, same(controller));
  });

  test('source projection signal follows refresh and controller adoption',
      () async {
    final firstRoot =
        await Directory.systemTemp.createTemp('zic-external-signal-a-');
    final secondRoot =
        await Directory.systemTemp.createTemp('zic-external-signal-b-');
    addTearDown(() => firstRoot.delete(recursive: true));
    addTearDown(() => secondRoot.delete(recursive: true));
    final first = await ExternalPluginController.openDeferred(
      firstRoot.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    final second = await ExternalPluginController.openDeferred(
      secondRoot.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(first.close);
    addTearDown(second.close);
    final lifecycle = HomeExternalSourceLifecycle(
      loaderProvider: () => null,
      sourceAvailable: (_) => false,
      isDeferredSource: (_) => true,
      refreshProjection: (_) async {},
    );
    addTearDown(lifecycle.close);
    var changes = 0;
    final subscription = lifecycle.sourceProjectionChanges.listen((_) {
      changes++;
    });
    addTearDown(subscription.cancel);

    lifecycle.initialize(first);
    await Future<void>.delayed(Duration.zero);
    expect(changes, 1);

    await lifecycle.refreshCurrentProjection();
    await Future<void>.delayed(Duration.zero);
    expect(changes, 2);

    lifecycle.adoptController(first);
    await Future<void>.delayed(Duration.zero);
    expect(changes, 2);

    lifecycle.adoptController(second);
    await Future<void>.delayed(Duration.zero);
    expect(changes, 3);
    expect(lifecycle.activeController, same(second));
  });

  test('exact source wait stays pending until loader handoff exists', () async {
    final root = await Directory.systemTemp.createTemp('zic-external-wait-');
    addTearDown(() => root.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      root.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    var loaderAvailable = false;
    var loaderCalls = 0;
    final lifecycle = HomeExternalSourceLifecycle(
      loaderProvider: () => loaderAvailable
          ? () async {
              loaderCalls++;
              return controller;
            }
          : null,
      sourceAvailable: (_) => false,
      isDeferredSource: (sourceId) => sourceId.startsWith('venera:'),
      refreshProjection: (_) async {},
    );
    addTearDown(lifecycle.close);

    var completed = false;
    final waiting = lifecycle.waitForSource('venera:missing').then((_) {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(loaderCalls, 0);

    loaderAvailable = true;
    lifecycle.signalLoaderAvailable();
    await waiting;

    expect(loaderCalls, 1);
    expect(completed, isTrue);
  });

  test('projection refresh is single-flight and drains one pending tail', () async {
    final root = await Directory.systemTemp.createTemp('zic-external-refresh-');
    addTearDown(() => root.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      root.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    final firstRefresh = Completer<void>();
    var refreshCalls = 0;
    final lifecycle = HomeExternalSourceLifecycle(
      loaderProvider: () => null,
      sourceAvailable: (_) => false,
      isDeferredSource: (_) => true,
      refreshProjection: (_) async {
        refreshCalls++;
        if (refreshCalls == 1) await firstRefresh.future;
      },
    );
    addTearDown(lifecycle.close);
    lifecycle.initialize(controller);

    final first = lifecycle.refreshCurrentProjection();
    await Future<void>.delayed(Duration.zero);
    final second = lifecycle.refreshCurrentProjection();
    final third = lifecycle.refreshCurrentProjection();
    expect(refreshCalls, 1);

    firstRefresh.complete();
    await Future.wait(<Future<void>>[first, second, third]);
    await Future<void>.delayed(Duration.zero);

    expect(refreshCalls, 2);
  });
}
