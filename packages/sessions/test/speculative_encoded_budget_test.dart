import 'dart:async';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('speculative bytes block further reads until capacity is released', () async {
    final budget = SpeculativeEncodedReadBudget(limitBytes: 1024);
    final firstControl = _Control(priority: 700);
    final secondControl = _Control(priority: 700);
    final first = budget.accountFor(firstControl, control: firstControl);
    final second = budget.accountFor(secondControl, control: secondControl);

    first.recordRead(1024);
    expect(budget.activeSpeculativeBytes, 1024);

    var entered = false;
    final wait = second.waitForRead().then((_) => entered = true);
    await Future<void>.delayed(Duration.zero);
    expect(entered, isFalse);

    first.close();
    await wait.timeout(const Duration(seconds: 1));
    expect(entered, isTrue);
    expect(budget.activeSpeculativeBytes, 0);
  });

  test('foreground promotion bypasses and releases speculative pressure', () async {
    final budget = SpeculativeEncodedReadBudget(limitBytes: 1024);
    final control = _Control(priority: 700);
    final account = budget.accountFor(control, control: control);
    account.recordRead(1024);
    expect(budget.activeSpeculativeBytes, 1024);

    var resumed = false;
    final wait = account.waitForRead().then((_) => resumed = true);
    await Future<void>.delayed(Duration.zero);
    expect(resumed, isFalse);

    control.updatePriority(1000);
    await wait.timeout(const Duration(seconds: 1));
    expect(resumed, isTrue);
    expect(budget.activeSpeculativeBytes, 0);

    account.recordRead(4096);
    expect(account.speculativeBytes, 1024,
        reason: 'foreground reads must not expand speculative usage');

    control.updatePriority(700);
    expect(budget.activeSpeculativeBytes, 1024,
        reason: 'earlier speculative read-ahead counts again after demotion');
  });

  test('dynamic limit update wakes blocked readers', () async {
    final budget = SpeculativeEncodedReadBudget(limitBytes: 512);
    final firstControl = _Control(priority: 700);
    final secondControl = _Control(priority: 700);
    final first = budget.accountFor(firstControl, control: firstControl);
    final second = budget.accountFor(secondControl, control: secondControl);
    first.recordRead(512);

    var resumed = false;
    final wait = second.waitForRead().then((_) => resumed = true);
    await Future<void>.delayed(Duration.zero);
    expect(resumed, isFalse);

    budget.updateLimitBytes(1024);
    await wait.timeout(const Duration(seconds: 1));
    expect(resumed, isTrue);
  });

  test('required-completion bypass can enter and leave without rebuilding account', () async {
    final budget = SpeculativeEncodedReadBudget(limitBytes: 1024);
    final control = _Control(priority: 700);
    final account = budget.accountFor(control, control: control);
    account.recordRead(1024);
    expect(budget.activeSpeculativeBytes, 1024);

    var resumed = false;
    final wait = account.waitForRead().then((_) => resumed = true);
    await Future<void>.delayed(Duration.zero);
    expect(resumed, isFalse);

    account.setBypassed(true);
    await wait.timeout(const Duration(seconds: 1));
    expect(resumed, isTrue);
    expect(budget.activeSpeculativeBytes, 0);

    account.setBypassed(false);
    expect(budget.activeSpeculativeBytes, 1024);
    expect(account.readBlocked, isTrue);
  });

}

final class _Control implements PriorityObservableTaskControl {
  _Control({required int priority}) : _priority = priority;

  int _priority;
  final Completer<void> _cancelled = Completer<void>();
  final StreamController<int> _priorities = StreamController<int>.broadcast();

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  @override
  int get priority => _priority;

  @override
  Stream<int> get priorityChanges => _priorities.stream;

  void updatePriority(int priority) {
    if (_priority == priority) return;
    _priority = priority;
    _priorities.add(priority);
  }
}
