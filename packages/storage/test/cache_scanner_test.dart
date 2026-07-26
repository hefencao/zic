import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late CacheLayout layout;
  late MemIndex index;

  final id = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page',
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/page.webp'),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cache_scanner_test_');
    layout = CacheLayout(temp.path);
    index = MemIndex();
    await index.open();
  });

  tearDown(() async {
    await index.close();
    await temp.delete(recursive: true);
  });

  test('rebuilds partial and ready records from artifact metadata', () async {
    final artifact = layout.artifactFor(id);
    await artifact.restore();
    await artifact.writeMeta(<String, Object?>{'download': id.toJson()});
    await artifact.append(0, <int>[1, 2, 3]);
    await artifact.pause();

    var report = await CacheScanner(layout: layout, index: index).scan();
    expect(report.recovered, 1);
    expect((await index.get(id.key))?.state, CacheState.partial);

    await artifact.restore();
    await artifact.seal(expectedLength: 3);
    await artifact.promote();
    report = await CacheScanner(layout: layout, index: index).scan();
    expect(report.recovered, 1);
    final ready = await index.get(id.key);
    expect(ready?.state, CacheState.ready);
    expect(ready?.bytes, 3);
    await artifact.dispose();
  });

  test('recovers staged final metadata after interrupted promote', () async {
    final artifact = layout.artifactFor(id);
    final data = File(artifact.finalPath);
    await data.parent.create(recursive: true);
    await data.writeAsBytes(<int>[1, 2, 3], flush: true);
    await File('${artifact.finalMetaPath}.tmp').writeAsString(
      jsonEncode(<String, Object?>{'download': id.toJson()}),
      flush: true,
    );

    final report = await CacheScanner(layout: layout, index: index).scan();
    expect(report.recovered, 1);
    expect(await File(artifact.finalMetaPath).exists(), isTrue);
    expect((await index.get(id.key))?.state, CacheState.ready);
  });

  test('does not delete an active orphan', () async {
    final orphan = File('${layout.partialDir}/active.part');
    await orphan.parent.create(recursive: true);
    await orphan.writeAsBytes(<int>[1]);

    final report = await CacheScanner(
      layout: layout,
      index: index,
      activePaths: <String>{orphan.path},
    ).scan();
    expect(report.protected, 1);
    expect(await orphan.exists(), isTrue);
  });
}
