import 'dart:async';

import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  _dev123NetLaneTests();
  test('queues by priority and keeps FIFO for equal priorities', () async {
    final lane = NetLane(maxActive: 1);
    final gate = Completer<void>();
    final order = <String>[];

    lane.submit(
      key: 'running',
      priority: 1,
      task: (_) async => gate.future,
    );
    lane.submit(
      key: 'low',
      priority: 10,
      task: (_) async => order.add('low'),
    );
    lane.submit(
      key: 'high-a',
      priority: 20,
      task: (_) async => order.add('high-a'),
    );
    lane.submit(
      key: 'high-b',
      priority: 20,
      task: (_) async => order.add('high-b'),
    );

    gate.complete();
    await lane.idle();
    expect(order, <String>['high-a', 'high-b', 'low']);
  });

  test('coalesces and cancels queued work by key', () async {
    final lane = NetLane(maxActive: 1);
    final gate = Completer<void>();
    final values = <int>[];

    lane.submit(key: 'running', priority: 1, task: (_) async => gate.future);
    lane.submit(key: 'same', priority: 1, task: (_) async => values.add(1));
    lane.submit(key: 'same', priority: 2, task: (_) async => values.add(2));
    expect(lane.cancelQueued('same'), isTrue);

    gate.complete();
    await lane.idle();
    expect(values, isEmpty);
  });
  test('replace cancels active work and runs the replacement next', () async {
    final lane = DecodeLane(maxActive: 1);
    final started = Completer<void>();
    final release = Completer<void>();
    final values = <String>[];

    lane.submit(
      key: 'same',
      priority: 1,
      task: (token) async {
        values.add('old');
        started.complete();
        await Future.any<void>(<Future<void>>[
          release.future,
          token.whenCancelled,
        ]);
      },
    );
    await started.future;
    lane.replace(
      key: 'same',
      priority: 2,
      task: (_) async => values.add('new'),
    );

    release.complete();
    await lane.idle();
    expect(values, <String>['old', 'new']);
  });


  test('follow queues one successor without cancelling active work', () async {
    final lane = UploadLane(maxActive: 1);
    final started = Completer<void>();
    final release = Completer<void>();
    final values = <String>[];

    lane.submit(
      key: 'same',
      priority: 1,
      task: (token) async {
        values.add('active');
        started.complete();
        await release.future;
        expect(token.cancelled, isFalse);
      },
    );
    await started.future;
    lane.follow(
      key: 'same',
      priority: 2,
      task: (_) async => values.add('old-follow'),
    );
    lane.follow(
      key: 'same',
      priority: 3,
      task: (_) async => values.add('latest-follow'),
    );

    release.complete();
    await lane.idle();
    expect(values, <String>['active', 'latest-follow']);
  });

  test('cancelAll clears pending work and signals active tokens', () async {
    final lane = NetLane(maxActive: 1);
    final started = Completer<void>();
    final activeCancelled = Completer<void>();
    var queuedRan = false;

    lane.submit(
      key: 'active',
      priority: 1,
      task: (token) async {
        started.complete();
        await token.whenCancelled;
        activeCancelled.complete();
      },
    );
    lane.submit(
      key: 'queued',
      priority: 2,
      task: (_) async {
        queuedRan = true;
      },
    );
    await started.future;

    lane.cancelAll();
    await activeCancelled.future;
    await lane.idle();

    expect(queuedRan, isFalse);
    expect(lane.queued, 0);
    expect(lane.active, 0);
  });

  test('ranked page work enforces global and per-source limits', () async {
    final lane = NetLane(maxActive: 5);
    final release = Completer<void>();
    final started = <String>[];

    for (var index = 0; index < 6; index++) {
      lane.submitRanked(
        key: 'remote-a-$index',
        priority: 800 - index,
        bucket: 'remote:a',
        bucketLimit: 3,
        task: (_) async {
          started.add('a$index');
          await release.future;
        },
      );
    }
    for (var index = 0; index < 4; index++) {
      lane.submitRanked(
        key: 'remote-b-$index',
        priority: 700 - index,
        bucket: 'remote:b',
        bucketLimit: 5,
        task: (_) async {
          started.add('b$index');
          await release.future;
        },
      );
    }

    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 5);
    expect(started.where((value) => value.startsWith('a')), hasLength(3));
    expect(started.where((value) => value.startsWith('b')), hasLength(2));

    release.complete();
    await lane.idle();
  });

  test('idleKeys ignores work owned by another Reader', () async {
    final lane = NetLane(maxActive: 2);
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();

    lane.submitRanked(
      key: 'reader-1:page',
      priority: 1000,
      bucket: 'local',
      bucketLimit: 5,
      task: (_) async => firstRelease.future,
    );
    lane.submitRanked(
      key: 'reader-2:page',
      priority: 1000,
      bucket: 'local',
      bucketLimit: 5,
      task: (_) async => secondRelease.future,
    );

    final firstIdle = lane.idleKeys(<String>['reader-1:page']);
    lane.cancel('reader-1:page');
    firstRelease.complete();
    await firstIdle;
    expect(lane.active, 1);

    secondRelease.complete();
    await lane.idle();
  });




}

// dev.123 current-page migration/preemption contracts.
void _dev123NetLaneTests() {
  test('active same-key promotion updates rank without restarting transfer', () async {
    final lane = NetLane(maxActive: 1);
    final started = Completer<void>();
    final release = Completer<void>();
    var runs = 0;

    lane.submitRanked(
      key: 'page',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        runs++;
        started.complete();
        await release.future;
      },
    );
    await started.future;

    expect(
      lane.submitRanked(
        key: 'page',
        priority: 1000,
        bucket: 'remote:a',
        bucketLimit: 5,
        task: (_) async => runs++,
      ),
      isFalse,
    );
    expect(lane.priorityOf('page'), 1000);
    expect(runs, 1);

    release.complete();
    await lane.idle();
    expect(runs, 1);
  });

  test('current uses one handoff slot and preempts the lowest ranked transfer',
      () async {
    final lane = NetLane(maxActive: 2, reservedHighPrioritySlots: 1);
    final lowCancelled = Completer<void>();
    final mediumRelease = Completer<void>();
    final currentStarted = Completer<void>();
    final currentRelease = Completer<void>();

    lane.submitRanked(
      key: 'low',
      priority: 680,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        await token.whenCancelled;
        lowCancelled.complete();
      },
    );
    lane.submitRanked(
      key: 'medium',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async => mediumRelease.future,
    );
    await Future<void>.delayed(Duration.zero);

    lane.submitRanked(
      key: 'current',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async {
        currentStarted.complete();
        await currentRelease.future;
      },
    );

    await currentStarted.future;
    expect(lane.active, 3);
    expect(lane.handoffActive, 1);
    await lowCancelled.future;
    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 2);

    currentRelease.complete();
    mediumRelease.complete();
    await lane.idle();
  });

  test('current preempts inside a full source bucket before global saturation',
      () async {
    final lane = NetLane(maxActive: 5, reservedHighPrioritySlots: 1);
    final firstCancelled = Completer<void>();
    final secondRelease = Completer<void>();
    final currentStarted = Completer<void>();
    final currentRelease = Completer<void>();

    lane.submitRanked(
      key: 'bucket-low',
      priority: 680,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        await token.whenCancelled;
        firstCancelled.complete();
      },
    );
    lane.submitRanked(
      key: 'bucket-near',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async => secondRelease.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 2);

    lane.submitRanked(
      key: 'bucket-current',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async {
        currentStarted.complete();
        await currentRelease.future;
      },
    );

    await currentStarted.future;
    expect(lane.active, 3);
    expect(lane.activeForBucket('remote:a'), 3);
    expect(lane.handoffActive, 1);
    await firstCancelled.future;

    currentRelease.complete();
    secondRelease.complete();
    await lane.idle();
  });

  test('handoff capacity stays bounded while cancellation unwinds', () async {
    final lane = NetLane(maxActive: 1, reservedHighPrioritySlots: 1);
    final lowRelease = Completer<void>();
    final firstCurrentStarted = Completer<void>();
    final firstCurrentRelease = Completer<void>();
    var secondCurrentStarted = false;

    lane.submitRanked(
      key: 'low',
      priority: 680,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async => lowRelease.future,
    );
    await Future<void>.delayed(Duration.zero);
    lane.submitRanked(
      key: 'current-a',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        firstCurrentStarted.complete();
        await firstCurrentRelease.future;
      },
    );
    await firstCurrentStarted.future;
    lane.submitRanked(
      key: 'current-b',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        secondCurrentStarted = true;
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(lane.active, 2);
    expect(secondCurrentStarted, isFalse);

    lowRelease.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(secondCurrentStarted, isTrue);

    firstCurrentRelease.complete();
    await lane.idle();
  });
}
