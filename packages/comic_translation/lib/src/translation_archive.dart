part of 'store.dart';

const _archiveByteLimit = 64 * 1024 * 1024;
const _archiveVariantLimit = 8;

Uint8List? _exportTranslationPage(Database db, String contentDigest) {
  final translations = db.select('''
    SELECT cache_key, payload, ocr_digest FROM translation_artifacts WHERE content_digest = ?
    ORDER BY accessed_at DESC, updated_at DESC, cache_key LIMIT ?;
  ''', [contentDigest, _archiveVariantLimit]);
  if (translations.isEmpty) return null;
  final ocrByDigest = <String, String>{};
  for (final row in db.select('''
    SELECT cache_key, payload, payload_digest FROM ocr_artifacts
    WHERE content_digest = ? ORDER BY accessed_at DESC LIMIT ?;
  ''', [contentDigest, _archiveVariantLimit * 2])) {
    final payload = row['payload'] as String;
    final digest = row['payload_digest'] as String? ??
        sha256.convert(utf8.encode(payload)).toString();
    if (row['payload_digest'] == null) {
      db.execute('UPDATE ocr_artifacts SET payload_digest = ? WHERE cache_key = ?;',
        [digest, row['cache_key']]);
    }
    ocrByDigest[digest] = payload;
  }
  final selected = <({String key, String payload})>[];
  final ocr = <String, String>{};
  var characters = 0;
  for (final row in translations) {
    final digest = row['ocr_digest'] as String;
    final payload = ocrByDigest[digest];
    if (payload == null) continue;
    final translation = row['payload'] as String;
    final added = translation.length + (ocr.containsKey(digest) ? 0 : payload.length);
    if (characters + added > _archiveByteLimit ~/ 2) continue;
    characters += added;
    ocr[digest] = payload;
    selected.add((key: row['cache_key'] as String, payload: translation));
  }
  if (selected.isEmpty) return null;
  // Recency selects the bounded set, but must not change its encoded order.
  // Otherwise an ordinary cache read defeats the owner's identical-write skip.
  selected.sort((a, b) => a.key.compareTo(b.key));
  final ocrKeys = ocr.keys.toList()..sort();
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
    'format': 'zic-page-translation', 'version': 1,
    'contentDigest': contentDigest,
    'ocr': {for (final digest in ocrKeys) digest: ocr[digest]},
    'translations': selected.map((entry) => entry.payload).toList(),
  })));
  return bytes.length > _archiveByteLimit ? null : bytes;
}

int _restoreTranslationPage(Database db, Uint8List bytes, String contentDigest) {
  if (bytes.isEmpty || bytes.length > _archiveByteLimit) {
    throw const FormatException('Translation archive size is invalid');
  }
  final envelope = jsonDecode(utf8.decode(bytes));
  if (envelope is! Map || envelope['format'] != 'zic-page-translation' ||
      envelope['version'] != 1 || envelope['contentDigest'] != contentDigest ||
      envelope['ocr'] is! Map || envelope['translations'] is! List) {
    throw const FormatException('Translation archive does not match this image');
  }
  final rawOcr = envelope['ocr'] as Map;
  final rawTranslations = envelope['translations'] as List;
  if (rawOcr.isEmpty || rawOcr.length > _archiveVariantLimit ||
      rawTranslations.isEmpty || rawTranslations.length > _archiveVariantLimit) {
    throw const FormatException('Translation archive variant limit is invalid');
  }
  final ocr = <String, ComicOcrArtifact>{};
  for (final entry in rawOcr.entries) {
    if (entry.key is! String || entry.value is! String ||
        sha256.convert(utf8.encode(entry.value as String)).toString() != entry.key) {
      throw const FormatException('Translation archive OCR digest is invalid');
    }
    final artifact = ComicOcrArtifact.fromJson(
      Map<String, dynamic>.from(jsonDecode(entry.value as String) as Map));
    if (artifact.contentDigest != contentDigest || artifact.imageWidth <= 0 ||
        artifact.imageHeight <= 0 || artifact.mediaKind != ComicTranslationMediaKind.staticImage) {
      throw const FormatException('Translation archive OCR identity is invalid');
    }
    ocr[entry.key as String] = artifact;
  }
  final translations = <ComicTranslationArtifact>[];
  for (final value in rawTranslations) {
    if (value is! String) throw const FormatException('Translation archive payload is invalid');
    final artifact = ComicTranslationArtifact.fromJson(
      Map<String, dynamic>.from(jsonDecode(value) as Map));
    final source = ocr[artifact.ocrDigest];
    if (source == null || artifact.contentDigest != contentDigest ||
        artifact.imageWidth != source.imageWidth || artifact.imageHeight != source.imageHeight ||
        artifact.sourceLanguage != source.sourceLanguage || artifact.mediaKind != source.mediaKind ||
        artifact.animatedMode != source.animatedMode) {
      throw const FormatException('Translation archive result identity is invalid');
    }
    translations.add(artifact);
  }
  // Validate every entry before changing the database. Preserve the exact OCR
  // payload bytes: its digest is the translation's content-addressed join key.
  final now = DateTime.now().millisecondsSinceEpoch;
  db.execute('BEGIN IMMEDIATE;');
  try {
    for (final entry in ocr.entries) {
      final artifact = entry.value;
      db.execute('''
        INSERT OR IGNORE INTO ocr_artifacts
          (cache_key, content_digest, engine_id, model_version, source_language,
           payload, payload_digest, updated_at, accessed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''', [ComicTranslationStore._ocrKey(contentDigest, artifact.engineId,
          artifact.modelVersion, artifact.sourceLanguage), contentDigest,
        artifact.engineId, artifact.modelVersion, artifact.sourceLanguage,
        rawOcr[entry.key], entry.key, now, now]);
    }
    for (var index = 0; index < translations.length; index++) {
      final artifact = translations[index];
      db.execute('''
        INSERT OR IGNORE INTO translation_artifacts
          (cache_key, content_digest, ocr_digest, engine_id, model_version,
           target_language, context_digest, payload, updated_at, accessed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''', [ComicTranslationStore._translationKey(artifact.ocrDigest, artifact.engineId,
          artifact.modelVersion, artifact.targetLanguage, artifact.contextDigest),
        contentDigest, artifact.ocrDigest, artifact.engineId, artifact.modelVersion,
        artifact.targetLanguage, artifact.contextDigest, rawTranslations[index], now, now]);
    }
    db.execute('''
      DELETE FROM ocr_artifacts WHERE rowid IN (
        SELECT rowid FROM ocr_artifacts ORDER BY accessed_at DESC LIMIT -1 OFFSET 2048
      );
      DELETE FROM translation_artifacts WHERE rowid IN (
        SELECT rowid FROM translation_artifacts ORDER BY accessed_at DESC LIMIT -1 OFFSET 4096
      );
    ''');
    db.execute('COMMIT;');
  } on Object {
    db.execute('ROLLBACK;');
    rethrow;
  }
  return translations.length;
}
