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
}
