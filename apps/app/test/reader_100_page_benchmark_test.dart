import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline/pipeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('100-page manifest and deterministic policy baseline', () async {
    final manifestWatch = Stopwatch()..start();
    final source = await rootBundle.loadString('assets/demo/chapter_001.json');
    final chapter = parseChapterManifest(source);
    manifestWatch.stop();

    final policyWatch = Stopwatch()..start();
    final policy = const HeuristicPolicy();
    final resolver = const RoleResolver();
    final target = DecodeTarget(
      physicalWidth: 1080,
      physicalHeight: 1920,
    );
    for (var index = 0; index < chapter.pages.length; index++) {
      final observation = ReaderObs(
        sessionId: 'benchmark',
        currentIndex: index,
        stableIndex: index,
        interaction: Interaction.idle,
        logicalPosition: index.toDouble(),
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: index,
          assetKey: chapter.pages[index].assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026, 7, 26),
        monotonicMicros: index,
      );
      final window = resolver.resolve(chapter, observation);
      final plan = policy.createPlan(
        revision: index + 1,
        chapter: chapter,
        observation: observation,
        window: window,
        decodeTarget: target,
      );
      expect(
        plan.downloads.values
            .where((demand) => demand.role == PageRole.current),
        hasLength(1),
      );
    }
    policyWatch.stop();

    expect(chapter.pages, hasLength(100));
    // Kept as trace output rather than a hard machine-dependent gate.
    // ignore: avoid_print
    print(
      'bench manifest_us=${manifestWatch.elapsedMicroseconds} '
      'policy_100_us=${policyWatch.elapsedMicroseconds}',
    );
  });
}
