import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:test/test.dart';

void main() {
  const resolver = ViewportResolver();

  test('idle keeps the current page dominant', () {
    final state = resolver.resolve(_obs(
      interaction: Interaction.idle,
      current: 1,
      currentFraction: 1,
    ));

    expect(state.phase, ViewportPhase.idle);
    expect(state.dominantPageIndex, 1);
    expect(state.freezesPresentation, isFalse);
  });

  test('significant two-page overlap freezes presentation', () {
    final state = resolver.resolve(_obs(
      interaction: Interaction.dragging,
      current: 1,
      currentFraction: 0.5,
      target: 2,
      targetFraction: 0.5,
    ));

    expect(state.phase, ViewportPhase.overlap);
    expect(state.dominantPageIndex, isNull);
    expect(state.freezesPresentation, isTrue);
  });

  test('target resumes when it becomes dominant', () {
    final state = resolver.resolve(_obs(
      interaction: Interaction.settling,
      current: 1,
      currentFraction: 0.3,
      target: 2,
      targetFraction: 0.7,
    ));

    expect(state.phase, ViewportPhase.dominant);
    expect(state.dominantPageIndex, 2);
    expect(state.freezesPresentation, isFalse);
  });

  test('continuous scrolling remains frozen until idle', () {
    final state = resolver.resolve(
      _obs(
        interaction: Interaction.scrolling,
        current: 1,
        currentFraction: 0.8,
        target: 2,
        targetFraction: 0.2,
      ),
      discretePages: false,
    );

    expect(state.phase, ViewportPhase.continuous);
    expect(state.dominantPageIndex, isNull);
    expect(state.freezesPresentation, isTrue);
  });
}

ReaderObs _obs({
  required Interaction interaction,
  required int current,
  required double currentFraction,
  int? target,
  double targetFraction = 0,
}) {
  return ReaderObs(
    sessionId: 'reader',
    currentIndex: current,
    stableIndex: current,
    interaction: interaction,
    logicalPosition: current.toDouble(),
    velocity: 0,
    currentCoverage: Coverage(
      pageIndex: current,
      assetKey: 'page-$current',
      fraction: currentFraction,
    ),
    targetCoverage: target == null
        ? null
        : Coverage(
            pageIndex: target,
            assetKey: 'page-$target',
            fraction: targetFraction,
          ),
    direction: ReadingDirection.ltr,
    timestamp: DateTime.utc(2026),
    monotonicMicros: 0,
  );
}
