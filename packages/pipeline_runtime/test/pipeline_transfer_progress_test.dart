import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

void main() {
  test('unknown-length transfer distinguishes connecting from receiving', () {
    const connecting = PipelineTransferProgress(
      active: true,
      existingBytes: 64,
      committedBytes: 64,
    );
    const receiving = PipelineTransferProgress(
      active: true,
      existingBytes: 64,
      committedBytes: 128,
    );

    expect(connecting.phase, PipelineTransferPhase.connecting);
    expect(connecting.receivedBytes, 0);
    expect(receiving.phase, PipelineTransferPhase.receiving);
    expect(receiving.receivedBytes, 64);
    expect(receiving.committedFraction, isNull);
  });

  test('local immutable reads are not presented as downloads', () {
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'local',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('content://reader/page.webp'),
    );
    final progress = pipelineTransferProgressFor(
      DownloadSnapshot(
        id: id,
        state: DownloadState.receiving,
        epoch: const SourceEpoch(0),
        committedLength: 1024,
        networkStartLength: 0,
        contentKind: ContentKind.webp,
        demanded: true,
        hasWriter: false,
        activeRun: true,
        artifact: const ArtifactSnapshot(
          state: ArtifactState.empty,
          committedLength: 0,
          checksum: '00000000',
          partialPath: '/tmp/partial',
          finalPath: '/tmp/final',
          metaPath: '/tmp/partial.meta',
          finalMetaPath: '/tmp/final.meta',
        ),
        totalLength: 4096,
      ),
    );

    expect(progress.phase, PipelineTransferPhase.idle);
  });

}
