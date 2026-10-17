import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('legacy OCR payload digest is backfilled without invalidating translations', () async {
    final directory = await Directory.systemTemp.createTemp('zic-translation-upgrade-');
    final store = ComicTranslationStore.instance;
    try {
      await store.init(directory.path);
      const ocr = ComicOcrArtifact(contentDigest: 'image-digest', engineId: 'ocr', modelVersion: '1',
        sourceLanguage: 'ja', imageWidth: 10, imageHeight: 10,
        mediaKind: ComicTranslationMediaKind.staticImage,
        animatedMode: AnimatedTranslationMode.posterFrame, regions: []);
      final digest = await store.storeOcr(ocr);
      expect(digest, ocr.digest);
      final translation = ComicTranslationArtifact(contentDigest: ocr.contentDigest,
        ocrDigest: digest, engineId: 'mt', modelVersion: '1', sourceLanguage: 'ja',
        targetLanguage: 'zh-CN', contextDigest: 'context', imageWidth: 10, imageHeight: 10,
        mediaKind: ComicTranslationMediaKind.staticImage,
        animatedMode: AnimatedTranslationMode.posterFrame, regions: []);
      await store.storeTranslation(translation);
      await store.close();
      final legacy = sqlite3.open('${directory.path}/comic_translation.db');
      // This is the deployed schema-1 table, before stored payload digests.
      legacy.execute('ALTER TABLE ocr_artifacts DROP COLUMN payload_digest;');
      legacy.dispose();
      await store.init(directory.path);
      final restored = await store.findOcrEntry(contentDigest: ocr.contentDigest,
        engineId: ocr.engineId, modelVersion: ocr.modelVersion, sourceLanguage: ocr.sourceLanguage);
      expect(restored!.digest, digest);
      expect(restored.artifact.toJson(), ocr.toJson());
      final translated = await store.findTranslation(ocrDigest: restored.digest,
        engineId: 'mt', modelVersion: '1', targetLanguage: 'zh-CN', contextDigest: 'context');
      expect(translated!.toJson(), translation.toJson());
      await store.close();
      final upgraded = sqlite3.open('${directory.path}/comic_translation.db');
      expect(upgraded.select('SELECT payload_digest FROM ocr_artifacts;').single[0], digest);
      expect(upgraded.select('PRAGMA user_version;').single[0], 1);
      upgraded.dispose();
    } finally {
      await store.close();
      await directory.delete(recursive: true);
    }
  });
}
