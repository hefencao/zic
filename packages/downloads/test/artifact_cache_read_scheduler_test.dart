import 'dart:async';

import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('reserves one process slot for foreground artifact reads', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final background = <ArtifactCacheReadLease>[];
    background.add(await scheduler.acquire(priority: () => 400));
    background.add(await scheduler.acquire(priority: () => 400));

    var thirdBackgroundStarted = false;
    final thirdBackground = scheduler.acquire(priority: () => 400).then((lease) {
      thirdBackgroundStarted = true;
      return lease;
    });
    await Future<void>.delayed(Duration.zero);
    expect(thirdBackgroundStarted, isFalse);

    final foreground = await scheduler.acquire(priority: () => 1000);
    expect(scheduler.activeCount, 3);
    foreground.release();
    await Future<void>.delayed(Duration.zero);
    expect(thirdBackgroundStarted, isFalse);

    background.removeLast().release();
    final third = await thirdBackground;
    expect(thirdBackgroundStarted, isTrue);
    third.release();
    for (final lease in background) {
      lease.release();
    }
  });

  test('queued foreground work outranks background work', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    final background = await scheduler.acquire(priority: () => 400);
    final foreground = scheduler.acquire(priority: () => 1000);
    final laterBackground = scheduler.acquire(priority: () => 720);

    final foregroundLease = await foreground;
    var laterStarted = false;
    unawaited(laterBackground.then((_) => laterStarted = true));
    await Future<void>.delayed(Duration.zero);
    expect(laterStarted, isFalse);

    foregroundLease.release();
    background.release();
    final later = await laterBackground;
    later.release();
  });

  test('refresh promotes an already queued artifact without cancellation', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final first = await scheduler.acquire(priority: () => 400);
    final second = await scheduler.acquire(priority: () => 400);
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

    lease.release();
    second.release();
    first.release();
  });
}
