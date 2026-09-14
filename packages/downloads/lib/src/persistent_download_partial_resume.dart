part of 'chapter_downloads.dart';

final class _IndexedPartialResumeState {
  const _IndexedPartialResumeState({
    this.validators = const Validators(),
    this.totalLength,
    this.explicitDifferentOwner = false,
  });

  final Validators validators;
  final int? totalLength;
  final bool explicitDifferentOwner;
}

Future<_IndexedPartialResumeState> _readPhysicalPartialResumeState(
  String partialPath,
  PhysicalMediaId physicalId,
  DownloadId requestId,
) async {
  final file = File('$partialPath.meta');
  if (!await file.exists()) return const _IndexedPartialResumeState();
  final Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on Object {
    return const _IndexedPartialResumeState();
  }
  if (decoded is! Map) return const _IndexedPartialResumeState();
  return _parsePhysicalPartialResumeState(
    Map<String, Object?>.from(decoded),
    physicalId,
    requestId,
  );
}

_IndexedPartialResumeState _parsePhysicalPartialResumeState(
  Map<String, Object?> meta,
  PhysicalMediaId physicalId,
  DownloadId requestId,
) {
  final rawPhysical = meta['physicalMedia'];
  if (rawPhysical is Map) {
    try {
      final metadataPhysical = PhysicalMediaId.fromJson(
        Map<String, Object?>.from(rawPhysical),
      );
      if (metadataPhysical != physicalId) {
        return const _IndexedPartialResumeState(explicitDifferentOwner: true);
      }
    } on Object {
      // Malformed acceleration metadata is not proof that indexed bytes are
      // foreign. Keep the prefix but resume without provider knowledge.
      return const _IndexedPartialResumeState();
    }
  }

  final rawLength = meta['totalLength'];
  final totalLength = rawLength is int ? rawLength : null;
  final rawProvider = meta['providerDownload'];
  if (rawProvider is! Map) {
    return _IndexedPartialResumeState(totalLength: totalLength);
  }
  final DownloadId provider;
  try {
    provider = DownloadId.fromJson(Map<String, Object?>.from(rawProvider));
  } on Object {
    return _IndexedPartialResumeState(totalLength: totalLength);
  }
  if (provider != requestId) {
    // Physical bytes and the encoded body's total length remain canonical
    // continuity facts. Only provider-scoped HTTP validators are discarded.
    return _IndexedPartialResumeState(totalLength: totalLength);
  }

  final rawValidators = meta['validators'];
  if (rawValidators is! Map || (rawLength != null && rawLength is! int)) {
    return _IndexedPartialResumeState(totalLength: totalLength);
  }
  try {
    var validators = Validators.fromJson(
      Map<String, Object?>.from(rawValidators),
    );
    final rawRequestUri = meta['validatorRequestUri'];
    final validatorRequestUri = rawRequestUri is String
        ? Uri.tryParse(rawRequestUri)
        : null;
    if (validators.canResume && validatorRequestUri != requestId.canonicalUri) {
      validators = const Validators();
    }
    return _IndexedPartialResumeState(
      validators: validators,
      totalLength: rawLength as int?,
    );
  } on Object {
    return const _IndexedPartialResumeState();
  }
}

Future<_IndexedPartialResumeState> _readIndexedPartialResumeState(
  String partialPath,
  DownloadId id,
) async {
  final file = File('$partialPath.meta');
  if (!await file.exists()) return const _IndexedPartialResumeState();
  final Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on Object {
    // Resume metadata is acceleration evidence, not authority over the
    // committed media prefix. Preserve indexed bytes and fall back to
    // validatorless continuation when metadata is malformed.
    return const _IndexedPartialResumeState();
  }
  if (decoded is! Map) return const _IndexedPartialResumeState();
  final meta = Map<String, Object?>.from(decoded);

  var matches = meta['downloadKey'] == id.key;
  var explicitDifferentOwner = false;
  final key = meta['downloadKey'];
  if (key is String && key != id.key) {
    explicitDifferentOwner = true;
  }
  final rawDownload = meta['download'];
  if (!matches && rawDownload is Map) {
    try {
      final metadataId = DownloadId.fromJson(
        Map<String, Object?>.from(rawDownload),
      );
      matches = metadataId == id;
      explicitDifferentOwner = metadataId != id;
    } on Object {
      // Malformed identity metadata is not proof that the indexed media bytes
      // belong to another object. Keep the prefix but drop resume knowledge.
    }
  }
  if (explicitDifferentOwner) {
    return const _IndexedPartialResumeState(explicitDifferentOwner: true);
  }
  if (!matches) return const _IndexedPartialResumeState();

  final rawValidators = meta['validators'];
  final rawLength = meta['totalLength'];
  if (rawValidators is! Map || (rawLength != null && rawLength is! int)) {
    return const _IndexedPartialResumeState();
  }
  try {
    var validators = Validators.fromJson(
      Map<String, Object?>.from(rawValidators),
    );
    final rawValidatorRequestUri = meta['validatorRequestUri'];
    final validatorRequestUri = rawValidatorRequestUri is String
        ? Uri.tryParse(rawValidatorRequestUri)
        : null;
    if (validators.canResume && validatorRequestUri != id.canonicalUri) {
      validators = const Validators();
    }
    return _IndexedPartialResumeState(
      validators: validators,
      totalLength: rawLength as int?,
    );
  } on Object {
    return const _IndexedPartialResumeState();
  }
}

Stream<List<int>> _readIndexedChunks(
  String path, {
  required int length,
  required int start,
  int? endExclusive,
}) async* {
  if (start < 0 || (endExclusive != null && endExclusive < start)) {
    throw RangeError('invalid indexed artifact range $start..$endExclusive');
  }
  if (start >= length) return;
  final limit = (endExclusive ?? length).clamp(start, length).toInt();
  final reader = await File(path).open();
  try {
    await reader.setPosition(start);
    var offset = start;
    while (offset < limit) {
      final readSize = (limit - offset)
          .clamp(1, promotedArtifactReadChunkBytes)
          .toInt();
      final chunk = await reader.read(readSize);
      if (chunk.isEmpty) break;
      offset += chunk.length;
      yield chunk;
    }
    if (offset != limit) {
      throw StateError('indexed artifact ended at $offset/$limit');
    }
  } finally {
    await reader.close();
  }
}

String _chapterDownloadPrefix(ImportedLibraryEntry entry) =>
    '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000'
    '${entry.chapter.chapterId}\u0000';

String chapterDownloadIdentity(
  String sourceId,
  String comicId,
  String chapterId,
  String sourceRevision,
) => '$sourceId\u0000$comicId\u0000$chapterId\u0000$sourceRevision';
