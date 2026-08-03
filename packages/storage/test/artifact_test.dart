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

  test('readPrefix awaits the read before closing the file', () async {
    final artifact = createArtifact();
    await artifact.restore();
    await artifact.append(0, <int>[1, 2, 3, 4]);
    await artifact.pause();

    expect(await artifact.readPrefix(3), <int>[1, 2, 3]);
    await artifact.dispose();
    expect(await File(artifact.partialPath).readAsBytes(), <int>[1, 2, 3, 4]);
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
