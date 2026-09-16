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
          uri: Uri.parse('$scheme://host/page-$index.png'),
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

  test('all source kinds share stable demand and decode/upload lanes', () {
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
      expect(plan.decodes, hasLength(11), reason: scheme);
      expect(plan.uploads, hasLength(11), reason: scheme);
      expect(
        plan.decodes.values.every((demand) => demand.targetWatermark == 1),
        isTrue,
        reason: '$scheme static work must remain one-frame only',
      );
      expect(
        plan.uploads.values.where((u) => u.role == PageRole.current),
        hasLength(1),
        reason: scheme,
      );
      expect(profile.networkConcurrency, 5, reason: scheme);
      expect(profile.localSourceConcurrency, 2, reason: scheme);
      expect(profile.remoteSourceConcurrency, 5, reason: scheme);
      expect(profile.decodeConcurrency, 3, reason: scheme);
      expect(profile.uploadConcurrency, 2, reason: scheme);
      expect(
        profile.speculativeExternalPresentationConcurrency,
        3,
        reason: '$scheme fast vertical static warming stays bounded',
      );
    }
  });
  test('download buckets separate local work and each remote source', () {
    final profile = ReaderPipelineProfile.stable;
    final local = _downloadId(
      sourceId: 'local',
      uri: Uri.parse('content://reader/page.webp'),
    );
    final firstRemote = _downloadId(
      sourceId: 'mihon-a',
      uri: Uri.parse('mihon-resource://host/page.webp'),
    );
    final secondRemote = _downloadId(
      sourceId: 'mihon-b',
      uri: Uri.parse('mihon-resource://host/page.webp'),
    );

    expect(profile.downloadBucket(local), 'local');
    expect(profile.downloadBucket(firstRemote), 'remote:mihon-a');
    expect(profile.downloadBucket(secondRemote), 'remote:mihon-b');
    expect(profile.downloadBucketLimit(local), 2);
    expect(profile.downloadBucketLimit(firstRemote), 5);
  });

  test('stable profile keeps logical 3/7 while animation flow is policy-owned', () {
    final chapter = manifest('https');
    final profile = readerPipelineProfileFor(chapter);
    final window = profile.windowResolver.resolve(chapter, observation(chapter));

    expect(window.roles, hasLength(11));
    expect(profile.policy.animatedPrefetchPolicy, isA<AnimatedPrefetchPolicy>());
    expect(profile.guard.maxDownloadDemands, 11);
  });

}


DownloadId _downloadId({required String sourceId, required Uri uri}) =>
    DownloadId(
      content: ContentId(
        sourceId: sourceId,
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
