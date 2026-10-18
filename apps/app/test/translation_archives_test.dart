import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:crypto/crypto.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/translation_archives.dart';

void main() {
  test('downloading an already translated page saves an archive without model work', () async {
    final root = await Directory.systemTemp.createTemp('zic-download-translation-');
    await Directory('${root.path}/translation').create();
    await ComicTranslationStore.instance.init('${root.path}/translation');
    final composition = await PersistentDownloadComposition.open(root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
      presentationFileLeaseFactory: _LocalFileLeases());
    final library = MemoryImportedLibraryStore();
    await library.open();
    final trace = MemoryTraceSink();
    final entered = Completer<void>();
    final initialize = Completer<void>();
    final archives = TranslationDownloadArchives(composition: composition, library: library,
      storageRoot: root.path, trace: trace, initialize: () {
        entered.complete();
        return initialize.future;
      });
    addTearDown(() async {
      await archives.close();
      await composition.close();
      await library.close();
      await ComicTranslationStore.instance.close();
      await root.delete(recursive: true);
    });
    final entry = ImportedLibraryEntry(chapter: ImportedChapterRecord(
      directoryId: 'archive-fixture', displayName: 'Chapter', sourceId: 'fixture',
      comicId: 'comic', chapterId: 'chapter', sourceRevision: 'r1',
      pages: const [ImportedPageRecord(displayName: 'Page', sourceId: 'https://example.invalid/page.webp',
        pageId: 'page', contentKindHint: ContentKindHint.webp, animatedHint: true)],
    ));
    await library.upsertChapter(entry.chapter);
    final manifest = entry.chapter.toManifest();
    final id = readerPageDownloadId(manifest, manifest.pages.single);
    final image = await File('test/device_acceptance/fixtures/source_native_webp/static.webp').readAsBytes();
    await composition.artifactStore.storePromotedArtifact(id: id, bytes: image);
    final content = sha256.convert(image).toString();
    final ocr = ComicOcrArtifact(contentDigest: content, engineId: 'fixture-ocr', modelVersion: 'v1',
      sourceLanguage: 'ja', imageWidth: 1, imageHeight: 1,
      mediaKind: ComicTranslationMediaKind.staticImage,
      animatedMode: AnimatedTranslationMode.posterFrame, regions: const []);
    final digest = await ComicTranslationStore.instance.storeOcr(ocr);
    final translation = ComicTranslationArtifact(contentDigest: content, ocrDigest: digest,
      engineId: 'fixture-translator', modelVersion: 'v1', sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      contextDigest: '', imageWidth: 1, imageHeight: 1,
      mediaKind: ComicTranslationMediaKind.staticImage,
      animatedMode: AnimatedTranslationMode.posterFrame, regions: const []);
    await ComicTranslationStore.instance.storeTranslation(translation);
    await composition.chapterDownloads.download(entry);
    await entered.future;
    var drained = false;
    final closing = archives.close().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    initialize.complete();
    await closing;
    final Uint8List? saved = await composition.artifactStore.readArtifactCompanion(id);
    expect(saved, isNotNull, reason: trace.events.map((event) => event.payload).join('\n'));
    expect(trace.events.where((event) => event.payload['stage'] == 'archive-backfill-failed'), isEmpty);
    await ComicTranslationStore.instance.clear();
    expect(await ComicTranslationStore.instance.restorePage(saved!, contentDigest: content), 1);
    final restored = await ComicTranslationStore.instance.findTranslation(ocrDigest: digest,
      engineId: translation.engineId, modelVersion: translation.modelVersion,
      targetLanguage: translation.targetLanguage, contextDigest: '');
    expect(restored!.toJson(), translation.toJson());
  });
}

final class _LocalFileLeases implements ArtifactPresentationFileLeaseFactory {
  @override
  Future<ArtifactCachePresentationFileLease?> open(String locator, {required int expectedLength}) async {
    if (await File(locator).length() != expectedLength) return null;
    return ArtifactCachePresentationFileLease(path: locator, length: expectedLength, release: () async {});
  }
}
