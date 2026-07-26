import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('observation keeps explicit current and target coverage', () {
    final observation = ReaderObs(
      sessionId: 's1',
      currentIndex: 3,
      stableIndex: 3,
      interaction: Interaction.dragging,
      logicalPosition: 3.4,
      velocity: 2,
      currentCoverage: Coverage(
        pageIndex: 3,
        assetKey: 'chapter/p3',
        fraction: 0.6,
      ),
      targetCoverage: Coverage(
        pageIndex: 4,
        assetKey: 'chapter/p4',
        fraction: 0.4,
      ),
      direction: ReadingDirection.rtl,
      timestamp: DateTime.utc(2026, 7, 26),
      monotonicMicros: 10,
    );

    expect(observation.targetCoverage?.pageIndex, 4);
    expect(observation.direction, ReadingDirection.rtl);
  });
}
