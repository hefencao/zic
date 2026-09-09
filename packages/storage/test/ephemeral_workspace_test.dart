import 'dart:io';
import 'dart:typed_data';

import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('reader workspace owns artifact reads and recursive cleanup', () async {
    final workspace = EphemeralCacheWorkspace.readerSession('reader/test');
    addTearDown(workspace.dispose);
    final artifact = Artifact(
      partialPath: '${workspace.rootPath}/partial/page.part',
      finalPath: '${workspace.rootPath}/final/page.bin',
    );
    final finalFile = File(artifact.finalPath);
    await finalFile.parent.create(recursive: true);
    await finalFile.writeAsBytes(<int>[1, 2, 3], flush: true);

    expect(
      await workspace.readArtifact(artifact),
      Uint8List.fromList(<int>[1, 2, 3]),
    );

    await workspace.dispose();
    expect(await Directory(workspace.rootPath).exists(), isFalse);
  });

  test('recoverable transfer workspace reopens partial after abrupt owner loss',
      () async {
    final stableId =
        'app-private-${DateTime.now().microsecondsSinceEpoch}-transfer-root';
    final first = EphemeralCacheWorkspace.recoverableTransfer(stableId);
    addTearDown(first.dispose);
    final firstArtifact = Artifact(
      partialPath: '${first.rootPath}/partial/page.part',
      finalPath: '${first.rootPath}/final/page.bin',
    );
    await firstArtifact.restore();
    await firstArtifact.append(0, <int>[1, 2, 3, 4, 5]);
    await firstArtifact.pause();
    await firstArtifact.dispose();

    // Do not dispose the first workspace before constructing the replacement:
    // this models Android task removal, where Dart cleanup never runs but the
    // app-private cache files remain available to the next process.
    final replacement = EphemeralCacheWorkspace.recoverableTransfer(stableId);
    expect(replacement.rootPath, first.rootPath);
    final replacementArtifact = Artifact(
      partialPath: '${replacement.rootPath}/partial/page.part',
      finalPath: '${replacement.rootPath}/final/page.bin',
    );
    final restored = await replacementArtifact.restore();
    expect(restored.committedLength, 5);
    expect(await replacementArtifact.readBytes(), <int>[1, 2, 3, 4, 5]);
    await replacementArtifact.dispose();
  });
}
