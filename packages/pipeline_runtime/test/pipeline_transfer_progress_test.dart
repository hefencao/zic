import 'dart:io';

import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('publisher follows resolved physical session for an exact alias', () async {
    final temp = await Directory.systemTemp.createTemp(
      'pipeline_transfer_progress_alias_',
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(temp.path),
      clock: SystemClock(),
    );
    final physicalId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic-old',
        chapterId: 'chapter-old',
        pageId: 'page-old',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.invalid/old.webp'),
    );
    final aliasId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic-new',
        chapterId: 'chapter-new',
        pageId: 'page-new',
      ),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.invalid/new.webp'),
    );
    final session = registry.get(physicalId);
    await session.restore();
    registry.aliasPhysical(id: aliasId, target: physicalId);
    final writer = session.acquireWriter();
    await session.bindResponse(
      validators: const Validators(),
      totalLength: 4096,
    );
    await session.append(writer, 0, List<int>.filled(1024, 0));

    final publisher = PipelineTransferProgressPublisher();
    publisher.select(registry.find(aliasId));

    expect(registry.find(aliasId), same(session));
    expect(publisher.notifier.value.active, isTrue);
    expect(publisher.notifier.value.committedBytes, 1024);
    expect(publisher.notifier.value.totalBytes, 4096);

    publisher.dispose();
    await session.reset();
    await registry.dispose();
    await temp.delete(recursive: true);
  });
}
