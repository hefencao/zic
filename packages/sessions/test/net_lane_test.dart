import 'dart:async';

import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
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

}
