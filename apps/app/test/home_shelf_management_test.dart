import 'package:flutter_test/flutter_test.dart';
import 'package:zic/home_shelf_management.dart';

void main() {
  test('management mode owns batch-selection invariants', () {
    final state = HomeShelfManagement();

    expect(state.managing, isFalse);
    expect(state.batchSelecting, isFalse);
    expect(state.hasSelection, isFalse);

    state.startBatchSelection('source:a');
    expect(state.hasSelection, isFalse);

    state.toggleManaging();
    expect(state.managing, isTrue);
    state.startBatchSelection('source:a');
    state.startBatchSelection('source:b');
    expect(state.batchSelecting, isTrue);
    expect(state.isSelected('source:a'), isTrue);
    expect(state.isSelected('source:b'), isTrue);

    state.toggleBatchSelection('source:a');
    expect(state.isSelected('source:a'), isFalse);
    expect(state.batchSelecting, isTrue);

    state.toggleBatchSelection('source:b');
    expect(state.hasSelection, isFalse);
    expect(state.batchSelecting, isFalse);
    expect(state.managing, isTrue);
  });

  test('mode changes and removals cannot leave stale batch state', () {
    final state = HomeShelfManagement()..toggleManaging();

    state.startBatchSelection('source:a');
    state.removeSelection('source:a');
    expect(state.batchSelecting, isFalse);
    expect(state.hasSelection, isFalse);

    state.startBatchSelection('source:b');
    state.toggleManaging();
    expect(state.managing, isFalse);
    expect(state.batchSelecting, isFalse);
    expect(state.hasSelection, isFalse);

    state.toggleManaging();
    state.startBatchSelection('source:c');
    state.clearSelection();
    expect(state.managing, isTrue);
    expect(state.batchSelecting, isFalse);
    expect(state.hasSelection, isFalse);
  });
}
