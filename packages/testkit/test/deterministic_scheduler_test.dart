import 'package:test/test.dart';
import 'package:testkit/testkit.dart';

void main() {
  test('higher priority runs first and equal priority remains FIFO', () async {
    final scheduler = DetScheduler();
    final order = <String>[];
    scheduler.schedule(key: 'near', priority: 10, body: () async => order.add('near'));
    scheduler.schedule(key: 'current-a', priority: 100, body: () async => order.add('a'));
    scheduler.schedule(key: 'current-b', priority: 100, body: () async => order.add('b'));

    await scheduler.runUntilIdle();
    expect(order, <String>['a', 'b', 'near']);
  });

  test('same key coalesces pending work', () async {
    final scheduler = DetScheduler();
    final order = <String>[];
    scheduler.schedule(key: 'page', priority: 1, body: () async => order.add('old'));
    scheduler.schedule(key: 'page', priority: 2, body: () async => order.add('new'));

    await scheduler.runUntilIdle();
    expect(order, <String>['new']);
  });
}
