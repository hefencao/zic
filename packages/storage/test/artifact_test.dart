import 'dart:io';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  final artifacts = <Artifact>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('artifact_test_');
  });

  tearDown(() async {
    for (final artifact in artifacts) {
      await artifact.dispose();
    }
    artifacts.clear();
    await temp.delete(recursive: true);
  });

  Artifact createArtifact() {
    final artifact = Artifact(
      partialPath: '${temp.path}/partial/page.bin',
      finalPath: '${temp.path}/cache/page.bin',
    );
    artifacts.add(artifact);
    return artifact;
  }

  test('restores arbitrary chunk boundaries and promotes atomically', () async {
    final artifact = createArtifact();
    await artifact.restore();
    await artifact.writeMeta(<String, Object?>{'fixture': true});
    await artifact.append(0, <int>[1, 2]);
    await artifact.append(2, <int>[3]);
    await artifact.append(3, <int>[4, 5, 6]);
    final sealed = await artifact.seal(expectedLength: 6);
    expect(sealed.committedLength, 6);

    final promoted = await artifact.promote();
    expect(promoted.state, ArtifactState.promoted);
    expect(await File(promoted.finalPath).readAsBytes(), <int>[1, 2, 3, 4, 5, 6]);
    expect(await File(promoted.partialPath).exists(), isFalse);
    expect(await File('${promoted.partialPath}.meta').exists(), isFalse);
    expect(await File('${promoted.finalPath}.meta').exists(), isTrue);
  });

  test('rejects symlinked artifact paths without touching the target',
      () async {
    if (Platform.isWindows) return;
    final artifact = createArtifact();
    final outside = File('${temp.path}/outside.bin');
    await outside.writeAsBytes(<int>[4, 5, 6]);
    await Link(artifact.partialPath).create(outside.path, recursive: true);

    await expectLater(
      artifact.restore(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );
    expect(await outside.readAsBytes(), <int>[4, 5, 6]);
  });

  test('partial adoption metadata rejects a symlinked sidecar', () async {
    if (Platform.isWindows) return;
    final artifact = createArtifact();
    final outside = File('${temp.path}/outside-meta.json');
    await outside.writeAsString('{"fixture":true}');
    await Link(artifact.metaPath).create(outside.path, recursive: true);

    await expectLater(
      artifact.readPartialMetaForAdoption(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );
    expect(await outside.readAsString(), '{"fixture":true}');
  });

  test('allows artifact paths under a symbolic-link ancestor mount point',
      () async {
    if (Platform.isWindows) return;
    final realRoot = Directory('${temp.path}/real_mount/cache');
    await realRoot.create(recursive: true);
    final linkMount = Link('${temp.path}/link_mount');
    await linkMount.create('${temp.path}/real_mount');
    final artifact = Artifact(
      partialPath: '${linkMount.path}/cache/partial/test.part',
      finalPath: '${linkMount.path}/cache/final/test.bin',
    );
    await Directory('${linkMount.path}/cache/partial').create(recursive: true);
    await File(artifact.partialPath).writeAsBytes(<int>[1, 2, 3]);
    final snapshot = await artifact.restore();
    expect(snapshot.state, ArtifactState.partial);
    expect(snapshot.committedLength, 3);
  });

  test('rejects non-contiguous append', () async {
    final artifact = createArtifact();
    await artifact.restore();
    await expectLater(
      artifact.append(1, <int>[1]),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.invalidOffset,
      )),
    );
  });

  test('flush checkpoint captures length before a later queued append', () async {
    final artifact = createArtifact();
    await artifact.restore();
    await artifact.append(0, <int>[1, 2, 3]);

    final checkpoint = artifact.flushCommittedLength();
    final laterAppend = artifact.append(3, <int>[4, 5]);

    expect(await checkpoint, 3);
    await laterAppend;
    expect(artifact.committedLength, 5);
    expect(await artifact.readBytes(), <int>[1, 2, 3, 4, 5]);
  });

  test('adopts indexed partial length without eager whole-file checksum', () async {
    final first = createArtifact();
    await first.restore();
    await first.append(0, List<int>.generate(4096, (index) => index & 0xff));
    await first.pause();
    await first.dispose();

    final second = createArtifact();
    final adopted = await second.adoptExistingPartial(expectedLength: 4096);

    expect(adopted.state, ArtifactState.partial);
    expect(adopted.committedLength, 4096);
    expect(adopted.checksum, isEmpty);
    await second.append(4096, <int>[1, 2, 3, 4]);
    final sealed = await second.seal(expectedLength: 4100);
    expect(sealed.checksum, isNotEmpty);
  });

  test('restores a durable partial prefix', () async {
    final first = createArtifact();
    await first.restore();
    await first.append(0, <int>[1, 2, 3]);
    await first.flush();
    await first.dispose();

    final second = createArtifact();
    final restored = await second.restore();
    expect(restored.state, ArtifactState.partial);
    expect(restored.committedLength, 3);
    await second.append(3, <int>[4]);
    await second.seal(expectedLength: 4);
    await second.promote();
  });
  test('restore keeps partial files closed until the first append', () async {
    final artifact = createArtifact();
    final restored = await artifact.restore();

    expect(restored.state, ArtifactState.partial);
    expect(artifact.hasOpenWriter, isFalse);

    await artifact.append(0, <int>[1, 2, 3]);
    expect(artifact.hasOpenWriter, isTrue);

    await artifact.pause();
    expect(artifact.hasOpenWriter, isFalse);
  });

  test('serializes concurrent append calls', () async {
    final artifact = createArtifact();
    await artifact.restore();

    await Future.wait<void>(<Future<void>>[
      artifact.append(0, <int>[1, 2]),
      artifact.append(2, <int>[3, 4]),
    ]);

    expect(artifact.committedLength, 4);
    await artifact.seal(expectedLength: 4);
  });

  test('append queued after reset cannot write into the deleted generation',
      () async {
    final artifact = createArtifact();
    await artifact.restore();

    final resetting = artifact.reset();
    final lateAppend = artifact.append(0, <int>[1, 2, 3]);

    await resetting;
    await expectLater(
      lateAppend,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.invalidState,
      )),
    );
    expect(artifact.committedLength, 0);
    expect(await File(artifact.partialPath).exists(), isFalse);
  });

  test('rejects sealing an empty artifact', () async {
    final artifact = createArtifact();
    await artifact.restore();

    await expectLater(
      artifact.seal(expectedLength: 0),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(artifact.state, ArtifactState.partial);
    expect(artifact.hasOpenWriter, isFalse);
  });

  test('rejects an empty promoted artifact during restore', () async {
    final artifact = createArtifact();
    await File(artifact.finalPath).parent.create(recursive: true);
    await File(artifact.finalPath).writeAsBytes(<int>[]);

    await expectLater(
      artifact.restore(),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(artifact.state, ArtifactState.empty);
    expect(artifact.hasOpenWriter, isFalse);
  });

  test('partial append defers crc until seal outside the download hot path',
      () async {
    final artifact = createArtifact();
    final bytes = '123456789'.codeUnits;
    await artifact.restore();

    await artifact.append(0, bytes);
    expect(artifact.snapshot.checksum, isEmpty);

    final sealed = await artifact.seal(
      expectedLength: bytes.length,
      expectedChecksum: 'cbf43926',
    );
    expect(sealed.checksum, 'cbf43926');
  });

  test('readPrefix flushes an open partial writer before reading', () async {
    final artifact = createArtifact();
    await artifact.restore();
    await artifact.append(0, <int>[1, 2, 3, 4]);

    expect(await artifact.readPrefix(3), <int>[1, 2, 3]);
    await artifact.pause();
    expect(await File(artifact.partialPath).readAsBytes(), <int>[1, 2, 3, 4]);
  });


  test('readers survive the sealed-to-promoted rename window', () async {
    final artifact = createArtifact();
    final bytes = List<int>.generate(256 * 1024 + 17, (index) => index & 0xff);
    await artifact.restore();
    await artifact.append(0, bytes);
    await artifact.seal(expectedLength: bytes.length);

    // Model the owner-internal promotion window after the data-file rename but
    // before ArtifactState advances to promoted. Reader code must not observe
    // this as an empty artifact.
    await File(artifact.finalPath).parent.create(recursive: true);
    await File(artifact.partialPath).rename(artifact.finalPath);

    expect(await artifact.readPrefix(12), bytes.sublist(0, 12));
    expect(await artifact.readBytes(), bytes);
    final replayed = <int>[];
    await for (final chunk in artifact.readChunks()) {
      replayed.addAll(chunk);
    }
    expect(replayed, bytes);
  });

  test('readChunks defaults to 256 KiB', () async {
    final artifact = createArtifact();
    final bytes = List<int>.filled(256 * 1024 * 2 + 7, 11);
    await artifact.restore();
    await artifact.append(0, bytes);
    await artifact.seal(expectedLength: bytes.length);
    await artifact.promote();

    final chunkLengths = await artifact.readChunks()
        .map((chunk) => chunk.length)
        .toList();

    expect(chunkLengths, <int>[256 * 1024, 256 * 1024, 7]);
  });

  test('readChunks streams an exact promoted range', () async {
    final artifact = createArtifact();
    final bytes = List<int>.generate(700000, (index) => index & 0xff);
    await artifact.restore();
    await artifact.append(0, bytes);
    await artifact.seal(expectedLength: bytes.length);
    await artifact.promote();

    final restored = <int>[];
    await for (final chunk in artifact.readChunks(
      start: 250000,
      endExclusive: 550000,
    )) {
      restored.addAll(chunk);
    }

    expect(restored, bytes.sublist(250000, 550000));
  });

  test('reads a promoted file larger than one MiB exactly', () async {
    final artifact = createArtifact();
    final bytes = List<int>.generate(
      1024 * 1024 + 257,
      (index) => index & 0xff,
    );
    await artifact.restore();
    await artifact.append(0, bytes);
    await artifact.seal(expectedLength: bytes.length);
    await artifact.promote();

    expect(await artifact.readBytes(), bytes);
  });

  test('promoted restore removes a stale partial generation', () async {
    final first = createArtifact();
    await first.restore();
    await first.append(0, <int>[1, 2, 3]);
    await first.seal(expectedLength: 3);
    await first.promote();
    await first.dispose();

    await File(first.partialPath).parent.create(recursive: true);
    await File(first.partialPath).writeAsBytes(<int>[9]);
    await File(first.metaPath).writeAsString('{"artifactState":"sealed"}');

    final second = createArtifact();
    final restored = await second.restore();

    expect(restored.state, ArtifactState.promoted);
    expect(await File(second.partialPath).exists(), isFalse);
    expect(await File(second.metaPath).exists(), isFalse);
    expect(await second.readBytes(), <int>[1, 2, 3]);
  });

  test('fast promoted restore trusts atomic metadata and reads once', () async {
    final first = createArtifact();
    final bytes = List<int>.generate(1024, (index) => index & 0xff);
    await first.restore();
    await first.writeMeta(<String, Object?>{'fixture': true});
    await first.append(0, bytes);
    await first.seal(expectedLength: bytes.length);
    final promoted = await first.promote();
    final expectedChecksum = promoted.checksum;
    await first.dispose();

    final second = createArtifact();
    final restored = await second.restore(verifyPromotedChecksum: false);

    expect(restored.state, ArtifactState.promoted);
    expect(restored.committedLength, bytes.length);
    expect(restored.checksum, expectedChecksum);
    expect(await second.readBytes(), bytes);
  });

  test('fast promoted restore repairs invalid metadata after rehash', () async {
    final first = createArtifact();
    await first.restore();
    await first.writeMeta(<String, Object?>{'fixture': true});
    await first.append(0, <int>[5, 4, 3, 2, 1]);
    await first.seal(expectedLength: 5);
    await first.promote();
    await first.dispose();
    await File(first.finalMetaPath).writeAsString('{invalid');

    final second = createArtifact();
    final restored = await second.restore(verifyPromotedChecksum: false);

    expect(restored.committedLength, 5);
    expect(await second.readBytes(), <int>[5, 4, 3, 2, 1]);
    expect(await second.readMeta(), containsPair('artifactState', 'ready'));
    expect(await second.readMeta(), containsPair('bytes', 5));
  });

  test('normal promoted restore repairs malformed metadata after rehash', () async {
    final first = createArtifact();
    await first.restore();
    await first.append(0, <int>[8, 7, 6]);
    await first.seal(expectedLength: 3);
    await first.promote();
    await first.dispose();
    await File(first.finalMetaPath).writeAsString('{invalid');

    final second = createArtifact();
    final restored = await second.restore();

    expect(restored.state, ArtifactState.promoted);
    expect(restored.committedLength, 3);
    expect(await second.readMeta(), containsPair('artifactState', 'ready'));
    expect(await second.readMeta(), containsPair('bytes', 3));
  });

  test('rejects same-length promoted corruption despite matching metadata length',
      () async {
    final first = createArtifact();
    await first.restore();
    await first.writeMeta(<String, Object?>{'fixture': true});
    await first.append(0, <int>[1, 2, 3, 4]);
    await first.seal(expectedLength: 4);
    await first.promote();
    await first.dispose();
    await File(first.finalPath).writeAsBytes(<int>[4, 3, 2, 1]);

    final second = createArtifact();
    await expectLater(
      second.restore(verifyPromotedChecksum: true),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(second.state, ArtifactState.empty);
    expect(second.committedLength, 0);
    expect(second.hasOpenWriter, isFalse);
  });

  test('fast promoted restore falls back when metadata length is stale', () async {
    final first = createArtifact();
    await first.restore();
    await first.writeMeta(<String, Object?>{'fixture': true});
    await first.append(0, <int>[1, 2, 3]);
    await first.seal(expectedLength: 3);
    await first.promote();
    await first.dispose();
    await File(first.finalPath).writeAsBytes(<int>[1, 2, 3, 4]);

    final second = createArtifact();
    final restored = await second.restore(verifyPromotedChecksum: false);

    expect(restored.committedLength, 4);
    expect(await second.readBytes(), <int>[1, 2, 3, 4]);
  });

}
