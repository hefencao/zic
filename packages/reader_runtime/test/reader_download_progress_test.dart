import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:transport/transport.dart';

void main() {
  test('idle partial projects bytes without pretending network activity', () {
    final progress = pipelineTransferProgressFor(
      _snapshot(
        DownloadState.idle,
        committedLength: 96,
        totalLength: 128,
      ),
    );

    expect(progress.active, isFalse);
    expect(progress.phase, PipelineTransferPhase.idle);
    expect(progress.partialBytes, 96);
    expect(progress.totalBytes, 128);
  });

  test('completed and failed artifacts never project transfer progress', () {
    for (final state in <DownloadState>[
      DownloadState.sealed,
      DownloadState.promoted,
      DownloadState.failed,
      DownloadState.disposed,
    ]) {
      final progress = pipelineTransferProgressFor(_snapshot(state));
      expect(progress.active, isFalse, reason: state.name);
      expect(progress.partialBytes, 0, reason: state.name);
      expect(progress.phase, PipelineTransferPhase.idle, reason: state.name);
    }
  });

  test('receiving projection separates physical partial from transport cursor', () {
    final progress = pipelineTransferProgressFor(
      _snapshot(
        DownloadState.receiving,
        committedLength: 96,
        networkStartLength: 64,
        totalLength: 128,
        networkAttemptActive: true,
        networkCursorLength: 32,
      ),
    );

    expect(progress.active, isTrue);
    expect(progress.phase, PipelineTransferPhase.replayingPrefix);
    expect(progress.partialBytes, 96);
    expect(progress.transportBytes, 32);
    expect(progress.totalBytes, 128);
  });

}

DownloadSnapshot _snapshot(
  DownloadState state, {
  int committedLength = 3,
  int networkStartLength = 3,
  int? totalLength = 3,
  bool networkAttemptActive = false,
  int networkCursorLength = 0,
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
      networkAttemptActive: networkAttemptActive,
      networkCursorLength: networkCursorLength,
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
