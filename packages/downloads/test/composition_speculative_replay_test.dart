import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('bound resident replay splits decoder range into 256 KiB physical quanta',
      () async {
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
    );
    addTearDown(runtime.dispose);
    final id = _id('bounded');
    final session = runtime.registry.get(id);
    const total = 700 * 1024;
    final ranges = <(int, int)>[];
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: total,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: const <int>[0xff, 0xd8, 0xff],
      residentReplayRangeChunks: (start, endExclusive) async {
        ranges.add((start, endExclusive));
        return Stream<List<int>>.value(
          Uint8List(endExclusive - start),
        );
      },
      residentReplayAccessMode: 'saf',
    );
    final control = CancelToken(priority: 700);
    final source = runtime.residentReplayRangeSourceWithControl(
      priorityFor: (_) => 700,
    );
    final stream = await source(
      session,
      0,
      total,
      control: control,
    );
    var received = 0;
    await for (final chunk in stream) {
      received += chunk.length;
    }

    expect(received, total);
    expect(
      ranges,
      <(int, int)>[
        (0, 256 * 1024),
        (256 * 1024, 512 * 1024),
        (512 * 1024, total),
      ],
    );
  });

  test('bound resident replay cancellation prevents the next physical quantum',
      () async {
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 2),
    );
    addTearDown(runtime.dispose);
    final id = _id('cancelled');
    final session = runtime.registry.get(id);
    const total = 700 * 1024;
    final ranges = <(int, int)>[];
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: total,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: const <int>[0xff, 0xd8, 0xff],
      residentReplayRangeChunks: (start, endExclusive) async {
        ranges.add((start, endExclusive));
        return Stream<List<int>>.value(
          Uint8List(endExclusive - start),
        );
      },
      residentReplayAccessMode: 'saf',
    );
    final control = CancelToken(priority: 700);
    final source = runtime.residentReplayRangeSourceWithControl(
      priorityFor: (_) => 700,
    );
    final stream = await source(
      session,
      0,
      total,
      control: control,
    );
    final iterator = StreamIterator<List<int>>(stream);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.length, 256 * 1024);
    control.cancel();
    await expectLater(
      iterator.moveNext(),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(ranges, <(int, int)>[(0, 256 * 1024)]);
    await iterator.cancel();
  });
}

DownloadId _id(String page) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: page,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/$page.webp'),
    );
