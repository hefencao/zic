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
}
