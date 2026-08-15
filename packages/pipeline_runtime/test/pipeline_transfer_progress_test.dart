import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';


final class _TestFrameScheduler implements PipelineFrameScheduler {
  const _TestFrameScheduler();

  @override
  bool get inPersistentCallbacks => false;

  @override
  bool get isIdle => true;

  @override
  void afterFrame(void Function() callback) => scheduleMicrotask(callback);

  @override
  void requestFrame() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unknown-length transfer distinguishes connecting, replay and receiving', () {
    const connecting = PipelineTransferProgress(
      active: true,
      partialBytes: 64,
      transportBytes: 0,
    );
    const replaying = PipelineTransferProgress(
      active: true,
      partialBytes: 128,
      transportBytes: 64,
      transportAttemptActive: true,
    );
    const receiving = PipelineTransferProgress(
      active: true,
      partialBytes: 64,
      transportBytes: 128,
      transportAttemptActive: true,
    );

    expect(connecting.phase, PipelineTransferPhase.connecting);
    expect(replaying.phase, PipelineTransferPhase.replayingPrefix);
    expect(replaying.replayingPrefix, isTrue);
    expect(receiving.phase, PipelineTransferPhase.receiving);
    expect(receiving.partialFraction, isNull);
    expect(receiving.transportFraction, isNull);
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
        totalLength: 128 * 1024,
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
      totalLength: 128 * 1024,
    );
    await session.append(writer, 0, List<int>.filled(1024, 0));

    session.beginNetworkAttemptProgress(0);
    session.advanceNetworkAttemptProgress(512, force: true);
    final publisher = PipelineTransferProgressPublisher(
      frameScheduler: const _TestFrameScheduler(),
    );
    publisher.select(registry.find(aliasId));

    expect(registry.find(aliasId), same(session));
    expect(publisher.feed.value.active, isTrue);
    expect(publisher.feed.value.partialBytes, 1024);
    expect(publisher.feed.value.transportBytes, 512);
    expect(publisher.feed.value.phase, PipelineTransferPhase.replayingPrefix);
    expect(publisher.feed.value.totalBytes, 128 * 1024);

    session.advanceNetworkAttemptProgress(1024 + 64 * 1024, force: true);
    await session.append(
      writer,
      1024,
      List<int>.filled(64 * 1024, 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(publisher.feed.value.partialBytes, 1024 + 64 * 1024);
    expect(publisher.feed.value.transportBytes, 1024 + 64 * 1024);

    publisher.dispose();
    await session.reset();
    await registry.dispose();
    await temp.delete(recursive: true);
  });
}
