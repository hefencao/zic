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
}
