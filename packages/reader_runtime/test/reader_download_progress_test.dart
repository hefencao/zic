import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:transport/transport.dart';

void main() {
  test('restored and completed artifacts never project network progress', () {
    for (final state in <DownloadState>[
      DownloadState.idle,
      DownloadState.sealed,
      DownloadState.promoted,
      DownloadState.failed,
      DownloadState.disposed,
    ]) {
      final progress = pipelineTransferProgressFor(_snapshot(state));
      expect(progress.active, isFalse, reason: state.name);
      expect(progress.phase, PipelineTransferPhase.idle, reason: state.name);
    }
  });

  test('receiving projection preserves the network resume baseline', () {
    final progress = pipelineTransferProgressFor(
      _snapshot(
        DownloadState.receiving,
        committedLength: 96,
        networkStartLength: 64,
        totalLength: 128,
      ),
    );

    expect(progress.active, isTrue);
    expect(progress.phase, PipelineTransferPhase.receiving);
    expect(progress.existingBytes, 64);
    expect(progress.receivedBytes, 32);
    expect(progress.totalBytes, 128);
  });
}

DownloadSnapshot _snapshot(
  DownloadState state, {
  int committedLength = 3,
  int networkStartLength = 3,
  int? totalLength = 3,
}) =>
    DownloadSnapshot(
      id: _id(),
      state: state,
      epoch: const SourceEpoch(0),
      committedLength: committedLength,
      networkStartLength: networkStartLength,
      contentKind: ContentKind.webp,
      demanded: true,
      hasWriter: state == DownloadState.receiving,
      activeRun: false,
      artifact: const ArtifactSnapshot(
        state: ArtifactState.promoted,
        committedLength: 3,
        checksum: '00000000',
        partialPath: '/partial/page.webp',
        finalPath: '/final/page.webp',
        metaPath: '/partial/page.webp.meta',
        finalMetaPath: '/final/page.webp.meta',
      ),
      totalLength: totalLength,
    );

DownloadId _id() => DownloadId(
      content: const ContentId(
        sourceId: 'mihon:fixture',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('mihon:resource:fixture'),
    );
