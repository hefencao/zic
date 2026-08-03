import 'dart:async';

import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('background uses full capacity without foreground pressure', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final leases = <ArtifactCacheReadLease>[
      await scheduler.acquire(priority: () => 400),
      await scheduler.acquire(priority: () => 400),
      await scheduler.acquire(priority: () => 400),
    ];

    expect(scheduler.activeCount, 3);
    expect(scheduler.activeBackgroundCount, 3);
    expect(scheduler.foregroundPressure, isFalse);

    for (final lease in leases) {
      lease.release();
    }
  });

  test('foreground pressure limits simultaneous background quanta', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final foreground = await scheduler.acquire(priority: () => 1000);
    final firstBackground = await scheduler.acquire(priority: () => 400);

    var secondBackgroundStarted = false;
    final secondBackground = scheduler.acquire(priority: () => 400).then(
      (lease) {
        secondBackgroundStarted = true;
        return lease;
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(scheduler.activeForegroundCount, 1);
    expect(scheduler.activeBackgroundCount, 1);
    expect(secondBackgroundStarted, isFalse);

    foreground.release();
    final second = await secondBackground;
    expect(secondBackgroundStarted, isTrue);
    expect(scheduler.activeBackgroundCount, 2);

    second.release();
    firstBackground.release();
  });

  test('queued foreground work outranks queued background work', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    final first = await scheduler.acquire(priority: () => 400);
    final second = await scheduler.acquire(priority: () => 400);
    final laterBackground = scheduler.acquire(priority: () => 720);
    var foregroundStarted = false;
    final foreground = scheduler.acquire(priority: () => 1000).then((lease) {
      foregroundStarted = true;
      return lease;
    });

    first.release();
    final foregroundLease = await foreground;
    expect(foregroundStarted, isTrue);

    var laterStarted = false;
    unawaited(laterBackground.then((_) => laterStarted = true));
    await Future<void>.delayed(Duration.zero);
    expect(laterStarted, isFalse);

    foregroundLease.release();
    second.release();
    final later = await laterBackground;
    later.release();
  });

  test('refresh promotes queued artifact without cancellation', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final foreground = await scheduler.acquire(priority: () => 1000);
    final background = await scheduler.acquire(priority: () => 400);
    var priority = 400;
    var promotedStarted = false;
    final promoted = scheduler.acquire(priority: () => priority).then((lease) {
      promotedStarted = true;
      return lease;
    });

    await Future<void>.delayed(Duration.zero);
    expect(promotedStarted, isFalse);
    priority = 1000;
    scheduler.refresh();
    final lease = await promoted;
    expect(lease.priority, 1000);
    expect(lease.foreground, isTrue);

    lease.release();
    background.release();
    foreground.release();
  });
}
