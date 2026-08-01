import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

void main() {
  ChapterManifest manifest(String scheme) {
    const count = 24;
    return ChapterManifest(
      sourceId: '$scheme-source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 0,
        pageCount: count,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        count,
        (index) => PageAsset(
          pageId: 'page-$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('$scheme://host/page-$index.webp'),
        ),
      ),
      readingDirection: ReadingDirection.ltr,
    );
  }

  ReaderObs observation(ChapterManifest chapter) => ReaderObs(
        sessionId: 'reader',
        currentIndex: 12,
        stableIndex: 12,
        interaction: Interaction.idle,
        logicalPosition: 12,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 12,
          assetKey: chapter.pages[12].assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      );

  test('all source kinds share the stable 7/3, 2/1, 5/3/2 profile', () {
    for (final scheme in <String>[
      'mihon-resource',
      'venera-resource',
      'https',
      'file',
    ]) {
      final chapter = manifest(scheme);
      final profile = readerPipelineProfileFor(chapter);
      final window = profile.windowResolver.resolve(
        chapter,
        observation(chapter),
      );
      final proposal = profile.policy.createPlan(
        revision: 1,
        chapter: chapter,
        observation: observation(chapter),
        window: window,
        decodeTarget: DecodeTarget(
          physicalWidth: 1080,
          physicalHeight: 1920,
        ),
      );
      final plan = profile.guard.enforce(proposal);

      expect(plan.downloads, hasLength(11), reason: scheme);
      expect(plan.decodes, hasLength(4), reason: scheme);
      expect(plan.uploads, hasLength(1), reason: scheme);
      expect(profile.networkConcurrency, 5, reason: scheme);
      expect(profile.decodeConcurrency, 3, reason: scheme);
      expect(profile.uploadConcurrency, 2, reason: scheme);
    }
  });
}
