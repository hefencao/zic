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

  test('cancelled control removes a pending local-read lease request', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    final first = await scheduler.acquire(priority: () => 1000);
    final second = await scheduler.acquire(priority: () => 1000);
    final control = _TestTaskControl(priority: 1000);
    final pending = scheduler.acquire(
      priority: () => 1000,
      control: control,
    );

    await Future<void>.delayed(Duration.zero);
    expect(scheduler.pendingCount, 1);
    control.cancel();

    await expectLater(
      pending,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(scheduler.pendingCount, 0);

    first.release();
    second.release();
  });

  test('cancelled pending read is skipped during a simultaneous lease release',
      () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    final blocker = await scheduler.acquire(priority: () => 1000);
    final secondBlocker = await scheduler.acquire(priority: () => 1000);
    final control = _TestTaskControl(priority: 400);
    final pending = scheduler.acquire(
      priority: () => 400,
      control: control,
    );

    control.cancel();
    blocker.release();
    secondBlocker.release();

    await expectLater(
      pending,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(scheduler.activeCount, 0);
    expect(scheduler.pendingCount, 0);
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

  test('startup pressure admits only one ranked background quantum', () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final pressure = scheduler.holdForegroundPressure();
    final lower = await scheduler.acquire(priority: () => 640);
    var higherStarted = false;
    final higher = scheduler.acquire(priority: () => 820).then((lease) {
      higherStarted = true;
      return lease;
    });

    await Future<void>.delayed(Duration.zero);
    expect(scheduler.foregroundPressure, isTrue);
    expect(scheduler.activeBackgroundCount, 1);
    expect(higherStarted, isFalse);

    lower.release();
    final next = await higher;
    expect(higherStarted, isTrue);

    pressure.release();
    next.release();
  });

  test('strict background waits until startup foreground pressure clears',
      () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final pressure = scheduler.holdForegroundPressure();
    var backgroundStarted = false;
    final background = scheduler
        .acquire(
          priority: () => 820,
          allowBackgroundDuringForegroundPressure: false,
        )
        .then((lease) {
      backgroundStarted = true;
      return lease;
    });

    await Future<void>.delayed(Duration.zero);
    expect(backgroundStarted, isFalse);
    expect(scheduler.activeBackgroundCount, 0);

    final current = await scheduler.acquire(priority: () => 1000);
    expect(current.foreground, isTrue);
    current.release();
    await Future<void>.delayed(Duration.zero);
    expect(backgroundStarted, isFalse,
        reason: 'the startup pressure hold still protects the physical executor');

    pressure.release();
    final lease = await background;
    expect(backgroundStarted, isTrue);
    lease.release();
  });
}

final class _TestTaskControl implements TaskControl {
  _TestTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();

  @override
  int priority;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
