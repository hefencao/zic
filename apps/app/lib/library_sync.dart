import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:catalog/catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:domain/domain.dart';
import 'package:network_bridge/network_bridge.dart';

const librarySyncFormat = 'zic-library-sync-v1';
const maxLibrarySyncBytes = 32 * 1024 * 1024;
const maxLibrarySyncRecords = 100000;

/// Contains only fixed validation messages, never remote content or locators.
final class LibrarySyncFormatException extends FormatException {
  const LibrarySyncFormatException(super.message);
}

/// Portable metadata only. Physical files, local locators and source secrets
/// never gain authority from a synchronized record.
final class LibrarySyncValue {
  LibrarySyncValue(this.data, this.initialTime) : fingerprint = syncFingerprint(data);
  final Map<String, Object?>? data;
  final int initialTime;
  final String fingerprint;
}

final class LibrarySyncRecord {
  LibrarySyncRecord({
    required this.key,
    required this.time,
    required this.writer,
    required this.data,
  }) : fingerprint = syncFingerprint(data);

  final String key;
  final int time;
  final String writer;
  final Map<String, Object?>? data;
  bool get deleted => data == null;
  final String fingerprint;
  String get kind => key.substring(0, key.indexOf(':'));
  String get identity => key.substring(key.indexOf(':') + 1);
  List<String> get parts => identity.split('\u0000');

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key, 'time': time, 'writer': writer, 'data': data,
  };

  factory LibrarySyncRecord.fromJson(Map<String, Object?> json) {
    final key = json['key'];
    final time = json['time'];
    final writer = json['writer'];
    final raw = json['data'];
    if (key is! String || key.length > 32768 ||
        time is! int || time < 0 || time > 8640000000000000 ||
        writer is! String || writer.isEmpty || writer.length > 128 ||
        (raw != null && raw is! Map)) {
      throw const LibrarySyncFormatException('无效的同步记录');
    }
    final data = raw == null ? null : Map<String, Object?>.from(raw as Map);
    final record = LibrarySyncRecord(
      key: key, time: time, writer: writer, data: data,
    );
    validateSyncRecord(record);
    if (record.kind == 'chapter' && data != null) {
      return LibrarySyncRecord(key: key, time: time, writer: writer,
        data: _portableChapter(ImportedChapterRecord.fromJson(data)));
    }
    return record;
  }
}

String syncFingerprint(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_ordered(value)))).toString();

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList(growable: false);
  return value;
}

bool _portableLocator(String value) {
  final uri = Uri.tryParse(value);
  return uri != null && uri.hasScheme &&
      !const <String>{'file', 'content', 'saf', 'data', 'blob', 'asset'}.contains(uri.scheme) &&
      uri.userInfo.isEmpty;
}

bool _portableCover(String value) {
  final uri = Uri.tryParse(value);
  return uri != null && const <String>{'http', 'https'}.contains(uri.scheme) &&
      uri.userInfo.isEmpty;
}

Map<String, Object?> _portableSaved(SavedComicRecord comic) {
  final data = comic.toJson();
  final cover = comic.coverSourceId;
  if (cover != null && !_portableCover(cover)) data.remove('coverSourceId');
  return data;
}

String librarySyncPageIdentity(ImportedPageRecord page) {
  final id = page.stablePageId;
  if (page.sourceId.startsWith(importedChapterSummaryPageSourcePrefix) &&
      RegExp(r'^zic-sync-page:[0-9a-f]{64}$').hasMatch(id)) return id;
  return 'zic-sync-page:' + syncFingerprint(id);
}

Map<String, Object?>? _portableChapter(ImportedChapterRecord chapter) {
  if (isLocalLibrarySource(chapter.sourceId) || chapter.isSummary ||
      chapter.pages.any((page) => !_portableLocator(page.sourceId))) return null;
  final data = chapter.toJson();
  data['directoryId'] = chapter.sourceId + ':' + chapter.comicId;
  // Resource URIs can encapsulate source headers/cookies and request bodies.
  // Synchronize logical pages only; the existing Home placeholder contract
  // requires source refresh before this chapter can enter Reader/downloads.
  data['pages'] = <Map<String, Object?>>[
    for (var i = 0; i < chapter.pages.length; i++) <String, Object?>{
      'displayName': (i + 1).toString(),
      'sourceId': importedChapterSummaryPageSourcePrefix + i.toString(),
      'pageId': librarySyncPageIdentity(chapter.pages[i]),
      'contentKindHint': chapter.pages[i].contentKindHint.name,
    },
  ];
  final cover = chapter.coverSourceId;
  if (cover != null && !_portableCover(cover)) data.remove('coverSourceId');
  return data;
}

Future<Map<String, LibrarySyncValue>> prepareLibrarySyncValues(
  ImportedLibraryBackupSnapshot snapshot,
  Map<String, Object?> readingSettings,
  [Map<String, int> readingTimes = const {}]
) => Isolate.run(() => buildLibrarySyncValues(snapshot, readingSettings, readingTimes));

Map<String, LibrarySyncValue> buildLibrarySyncValues(
  ImportedLibraryBackupSnapshot snapshot,
  Map<String, Object?> readingSettings,
  [Map<String, int> readingTimes = const {}]
) {
  final result = <String, LibrarySyncValue>{};
  void put(String key, Map<String, Object?> data, DateTime time) {
    result[key] = LibrarySyncValue(data, time.toUtc().microsecondsSinceEpoch);
  }
  for (final comic in snapshot.savedComics) {
    put('comic:' + comic.identity, _portableSaved(comic), comic.updatedAt);
  }
  for (final entry in snapshot.entries) {
    final chapter = _portableChapter(entry.chapter);
    if (chapter != null) {
      put('chapter:' + entry.identity, chapter, entry.chapter.importedAt);
    }
    final progress = entry.progress;
    if (progress != null) {
      put('progress:' + progress.identity, progress.toJson(), progress.updatedAt);
    }
  }
  for (final category in snapshot.categories) {
    put('category:' + category.categoryId, category.toJson(), category.updatedAt);
  }
  for (final preference in snapshot.comicPreferences) {
    put('preference:' + preference.identity,
      preference.toJson(), preference.updatedAt);
  }
  for (final state in snapshot.chapterReadStates) {
    put('read:' + state.identity, state.toJson(), state.updatedAt);
  }
  for (final source in snapshot.sourcePreferences) {
    put('source:' + source.sourceId, source.toJson(), source.updatedAt);
  }
  for (final entry in readingSettings.entries) {
    result[entry.key] = LibrarySyncValue(
      Map<String, Object?>.from(entry.value! as Map), readingTimes[entry.key] ?? 0,
    );
  }
  for (final entry in readingTimes.entries) {
    if (entry.key.startsWith('reader:') && entry.key != 'reader:global' &&
        !readingSettings.containsKey(entry.key)) {
      result[entry.key] = LibrarySyncValue(null, entry.value);
    }
  }
  if (result.length > maxLibrarySyncRecords) {
    throw const LibrarySyncFormatException('同步记录数量超出上限');
  }
  return result;
}

void validateSyncRecord(LibrarySyncRecord record) {
  final separator = record.key.indexOf(':');
  if (separator < 1) throw const LibrarySyncFormatException('无效的同步记录标识');
  final kind = record.kind;
  final parts = record.parts;
  if (!const <String>{
    'comic', 'chapter', 'progress', 'category', 'preference', 'read', 'reader', 'source', 'setting',
  }.contains(kind) || record.identity.isEmpty ||
      (kind != 'category' && kind != 'source' && !(kind == 'reader' && record.identity == 'global') &&
       (parts.length != 2 || parts.any((part) => part.isEmpty)))) {
    throw const LibrarySyncFormatException('无效的同步记录标识');
  }
  final data = record.data;
  if ((record.key == 'reader:global' || kind == 'source') && data == null) {
    throw const LibrarySyncFormatException('全局阅读或漫画源设置不可删除');
  }
  if (data == null) return;
  String expected;
  switch (kind) {
    case 'comic':
      final value = SavedComicRecord.fromJson(data);
      expected = value.identity;
      if (value.coverSourceId != null &&
          !_portableCover(value.coverSourceId!)) {
        throw const LibrarySyncFormatException('同步书架包含不可移植封面');
      }
    case 'chapter':
      final value = ImportedChapterRecord.fromJson(data);
      if (_portableChapter(value) == null ||
          value.directoryId != value.sourceId + ':' + value.comicId ||
          value.pages.asMap().entries.any((entry) => entry.value.sourceId !=
            importedChapterSummaryPageSourcePrefix + entry.key.toString()) ||
          (value.coverSourceId != null &&
           !_portableCover(value.coverSourceId!))) {
        throw const LibrarySyncFormatException('同步章节包含文件路径或请求定位符');
      }
      expected = chapterLibraryIdentity(value.sourceId, value.chapterId);
    case 'progress':
      final value = ReadingProgress.fromJson(data);
      if (value.pageIndex < 0 || !value.subPageOffset.isFinite ||
          value.subPageOffset < 0 || value.subPageOffset > 1) {
        throw const LibrarySyncFormatException('无效的同步阅读进度');
      }
      expected = value.identity;
    case 'category':
      expected = LibraryCategory.fromJson(data).categoryId;
    case 'preference':
      expected = ComicPreference.fromJson(data).identity;
    case 'read':
      expected = ChapterReadState.fromJson(data).identity;
    case 'reader':
      // AppPreferencesController validates the allowlisted settings before
      // any network write or library mutation.
      expected = record.identity;
    case 'source':
      expected = ComicSourcePreference.fromJson(data).sourceId;
    case 'setting':
      // PortableSettingsOwner validates the feature-specific allowlist before
      // publication or any local mutation.
      expected = record.identity;
    default:
      throw const LibrarySyncFormatException('未知的同步记录类型');
  }
  if (expected != record.identity) {
    throw const LibrarySyncFormatException('同步记录内容与标识不一致');
  }
}

Map<String, LibrarySyncRecord> decodeLibrarySync(List<int> bytes) {
  if (bytes.length > maxLibrarySyncBytes) {
    throw const LibrarySyncFormatException('云端同步数据超过 32 MiB');
  }
  var json = jsonDecode(utf8.decode(bytes));
  if (json is Map && json['format'] == librarySyncFormat &&
      json['recordsGzip'] is String && !json.containsKey('records')) {
    try {
      final unpacked = const MetadataGzipCodec().decode(
        base64Decode(json['recordsGzip'] as String), maxBytes: maxLibrarySyncBytes);
      json = jsonDecode(utf8.decode(unpacked));
    } on MetadataGzipLimitException {
      throw const LibrarySyncFormatException('云端同步数据超过 32 MiB');
    }
  }
  if (json is! Map || json['format'] != librarySyncFormat ||
      json['records'] is! List ||
      (json['records'] as List).length > maxLibrarySyncRecords) {
    throw const LibrarySyncFormatException('云端文件不是受支持的 ZIC 同步数据');
  }
  final records = <String, LibrarySyncRecord>{};
  for (final raw in json['records'] as List) {
    if (raw is! Map) throw const LibrarySyncFormatException('无效的云端同步记录');
    final record = LibrarySyncRecord.fromJson(Map<String, Object?>.from(raw));
    if (records.containsKey(record.key)) {
      throw const LibrarySyncFormatException('云端同步记录标识重复');
    }
    records[record.key] = record;
  }
  return records;
}

List<int> encodeLibrarySync(Map<String, LibrarySyncRecord> records, {bool compress = true}) {
  if (records.length > maxLibrarySyncRecords) {
    throw const LibrarySyncFormatException('同步记录数量超出上限');
  }
  for (final entry in records.entries) {
    final record = entry.value;
    if (entry.key != record.key || record.key.length > 32768 ||
        record.time < 0 || record.time > 8640000000000000 ||
        record.writer.isEmpty || record.writer.length > 128) {
      throw const LibrarySyncFormatException('无效的同步记录');
    }
    validateSyncRecord(record);
  }
  final keys = records.keys.toList()..sort();
  final bytes = utf8.encode(jsonEncode(<String, Object?>{
    'format': librarySyncFormat,
    'records': <Map<String, Object?>>[
      for (final key in keys) records[key]!.toJson(),
    ],
  }));
  if (bytes.length > maxLibrarySyncBytes) {
    throw const LibrarySyncFormatException('同步数据超过 32 MiB');
  }
  if (compress && bytes.length >= 64 * 1024) {
    final packed = utf8.encode(jsonEncode(<String, Object?>{
      'format': librarySyncFormat,
      'recordsGzip': base64Encode(const MetadataGzipCodec().encode(bytes)),
    }));
    if (packed.length < bytes.length) return packed;
  }
  return bytes;
}

/// A deterministic record register: edits/deletions win by logical timestamp,
/// then writer id and payload. Reading backwards remains a valid newer edit.
Map<String, LibrarySyncRecord> mergeLibrarySync(
  Map<String, LibrarySyncRecord> local,
  Map<String, LibrarySyncRecord> remote,
) {
  final result = <String, LibrarySyncRecord>{...remote};
  for (final entry in local.entries) {
    final other = result[entry.key];
    final value = entry.value;
    if (other == null || _compare(value, other) > 0) result[entry.key] = value;
  }
  final deletedCategories = <String, LibrarySyncRecord>{
    for (final record in result.values)
      if (record.kind == 'category' && record.deleted) record.identity: record,
  };
  for (final record in result.values.toList(growable: false)) {
    if (record.kind != 'preference' || record.deleted) continue;
    final preference = ComicPreference.fromJson(record.data!);
    final removed = preference.categoryIds.where(deletedCategories.containsKey).toList();
    if (removed.isEmpty) continue;
    var time = record.time;
    var writer = record.writer;
    for (final id in removed) {
      final deletion = deletedCategories[id]!;
      if (deletion.time > time) {
        time = deletion.time;
        writer = deletion.writer;
      }
    }
    result[record.key] = LibrarySyncRecord(
      key: record.key, time: time, writer: writer,
      data: preference.copyWith(
        categoryIds: preference.categoryIds.where((id) => !deletedCategories.containsKey(id)),
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(time, isUtc: true),
      ).toJson(),
    );
  }
  return result;
}

int _compare(LibrarySyncRecord left, LibrarySyncRecord right) {
  final time = left.time.compareTo(right.time);
  if (time != 0) return time;
  // Deletion wins an exact timestamp tie, regardless of device identity.
  final deleted = (left.deleted ? 1 : 0).compareTo(right.deleted ? 1 : 0);
  if (deleted != 0) return deleted;
  final writer = left.writer.compareTo(right.writer);
  return writer != 0 ? writer : left.fingerprint.compareTo(right.fingerprint);
}

Future<({
  Map<String, LibrarySyncRecord> records,
  Map<String, Map<String, Object?>> versions,
})> captureLibrarySync(
  Map<String, LibrarySyncValue> values,
  Map<String, Map<String, Object?>> versions,
  String device,
  int now,
  Map<String, Object?> defaultReading,
) => Isolate.run(() {
  final records = <String, LibrarySyncRecord>{};
  final nextVersions = <String, Map<String, Object?>>{};
  final keys = <String>{...versions.keys, ...values.keys};
  if (keys.length > maxLibrarySyncRecords) {
    throw const LibrarySyncFormatException('同步记录数量超出上限');
  }
  for (final key in keys) {
    final value = values[key];
    final hash = value?.fingerprint ?? syncFingerprint(null);
    final previous = versions[key];
    // Preference LRU eviction is local capacity management, not a cloud delete.
    // Explicit clearing is represented by a timed null value above.
    if (value == null && ((key.startsWith('reader:') && key != 'reader:global') ||
        key.startsWith('setting:') || key.startsWith('source:'))) {
      if (previous != null) nextVersions[key] = previous;
      continue;
    }
    final changed = previous != null && previous['hash'] != hash;
    var initial = value?.initialTime ?? now;
    if (initial == 0 && (key.startsWith('reader:') || key.startsWith('setting:')) &&
        hash != syncFingerprint(defaultReading[key])) initial = now;
    final time = previous == null ? initial
        : changed ? max(value?.initialTime ?? now, (previous['time']! as int) + 1)
            : previous['time']! as int;
    final writer = previous == null || changed ? device : previous['writer']! as String;
    records[key] = LibrarySyncRecord(
      key: key, time: time, writer: writer,
      data: _withClock(key, value?.data, time),
    );
    nextVersions[key] = <String, Object?>{'hash': hash, 'time': time, 'writer': writer};
  }
  return (records: records, versions: nextVersions);
});

Map<String, Object?>? _withClock(String key, Map<String, Object?>? data, int time) {
  if (data == null) return null;
  final kind = key.substring(0, key.indexOf(':'));
  final field = switch (kind) {
    'comic' || 'progress' || 'preference' || 'read' || 'source' => 'updatedAt',
    'chapter' => 'importedAt',
    _ => null,
  };
  if (field == null) return data;
  return <String, Object?>{...data,
    field: DateTime.fromMicrosecondsSinceEpoch(time, isUtc: true).toIso8601String(),
  };
}

LibrarySyncRecord restoreLibrarySyncRecord(LibrarySyncRecord record, int time, String writer) =>
    LibrarySyncRecord.fromJson({
      ...record.toJson(), 'time': time, 'writer': writer,
      'data': _withClock(record.key, record.data, time),
    });
