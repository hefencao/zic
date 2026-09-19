import 'dart:convert';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

import 'source_catalog.dart';

final class MangaDexSource implements BrowsableComicSource {
  MangaDexSource({
    Transport? transport,
    this.translatedLanguage = 'en',
    this.useDataSaver = false,
    this.maxNetworkAttempts = 2,
    String Function()? userAgentProvider,
  })  : assert(translatedLanguage != ''),
        assert(maxNetworkAttempts > 0 && maxNetworkAttempts <= 3),
        _transport = transport ??
            IoTransport(
              http: HttpTransport(
                connectionTimeout: const Duration(seconds: 15),
                userAgentProvider: userAgentProvider,
              ),
            );

  static final Uri _apiRoot = Uri.https('api.mangadex.org', '/');
  static final Uri _uploadsRoot = Uri.https('uploads.mangadex.org', '/');
  static const int _maxMetadataBytes = 4 * 1024 * 1024;
  static const int _maxResourceBytes = 16 * 1024 * 1024;

  @override
  String get sourceId => descriptor.sourceId;

  @override
  final ComicSourceDescriptor descriptor = ComicSourceDescriptor(
    sourceId: 'mangadex',
    name: 'MangaDex',
    language: 'English',
    website: Uri.https('mangadex.org', '/'),
  );

  final String translatedLanguage;
  final bool useDataSaver;
  final int maxNetworkAttempts;
  final Transport _transport;
  final Map<String, Comic> _comicCache = <String, Comic>{};

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be non-negative');
    }
    final pageSize = limit.clamp(1, 100).toInt();
    final parameters = <String, Object>{
      'limit': '$pageSize',
      'offset': '$offset',
      'includes[]': const <String>['cover_art', 'author', 'artist'],
      'availableTranslatedLanguage[]': <String>[translatedLanguage],
      'contentRating[]': const <String>['safe', 'suggestive'],
      'order[latestUploadedChapter]': 'desc',
      if (query.trim().isNotEmpty) 'title': query.trim(),
    };
    final payload = await _getObject(_api('/manga', parameters));
    final data = _objectList(payload, 'data');
    final items = data.map(_parseSummary).toList(growable: false);
    final total = _optionalInt(payload['total']) ?? offset + items.length;
    return SourceBrowsePage(
      items: items,
      offset: offset,
      hasMore: offset + items.length < total,
    );
  }

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    final mangaPayload = await _getObject(
      _api('/manga/$comicId', <String, Object>{
        'includes[]': const <String>['cover_art', 'author', 'artist'],
      }),
    );
    final mangaData = _requiredObject(mangaPayload, 'data');
    final comic = _parseComic(mangaData);
    _comicCache[comicId] = comic;

    final chapters = <Chapter>[];
    var offset = 0;
    const pageSize = 100;
    while (true) {
      final payload = await _getObject(
        _api('/manga/$comicId/feed', <String, Object>{
          'limit': '$pageSize',
          'offset': '$offset',
          'translatedLanguage[]': <String>[translatedLanguage],
          'contentRating[]': const <String>['safe', 'suggestive'],
          'order[chapter]': 'asc',
          'order[publishAt]': 'asc',
        }),
      );
      final data = _objectList(payload, 'data');
      for (final value in data) {
        final attributes = _requiredObject(value, 'attributes');
        final pageCount = _optionalInt(attributes['pages']) ?? 0;
        if (pageCount <= 0) {
          continue;
        }
        final chapterId = _requiredString(value, 'id');
        final chapterNumber = _optionalString(attributes['chapter']);
        final explicitTitle = _optionalString(attributes['title']);
        chapters.add(
          Chapter(
            chapterId: chapterId,
            comicId: comicId,
            title: _chapterTitle(chapterNumber, explicitTitle),
            sequence: _chapterSequence(chapterNumber, chapters.length),
            pageCount: pageCount,
            publishedAt: _optionalDateTime(attributes['publishAt']),
            updatedAt: _optionalDateTime(attributes['updatedAt']),
            sourceRevision: _optionalString(attributes['updatedAt']) ??
                _optionalString(attributes['createdAt']) ??
                chapterId,
          ),
        );
      }
      final total = _optionalInt(payload['total']) ?? offset + data.length;
      offset += data.length;
      if (data.isEmpty || offset >= total) {
        break;
      }
    }
    return ComicManifest(comic: comic, chapters: chapters);
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    final chapterPayload = await _getObject(
      _api('/chapter/$chapterId', <String, Object>{
        'includes[]': const <String>['manga'],
      }),
    );
    final chapterData = _requiredObject(chapterPayload, 'data');
    final attributes = _requiredObject(chapterData, 'attributes');
    final comicId = _relationshipId(chapterData, 'manga');
    if (comicId == null) {
      throw const FormatException('MangaDex chapter is missing manga identity');
    }
    final comic = _comicCache[comicId] ?? await _loadComicIdentity(comicId);

    final atHome = await _getObject(_api('/at-home/server/$chapterId'));
    final baseUrl = Uri.parse(_requiredString(atHome, 'baseUrl'));
    final remoteChapter = _requiredObject(atHome, 'chapter');
    final hash = _requiredString(remoteChapter, 'hash');
    final key = useDataSaver ? 'dataSaver' : 'data';
    final names = _stringList(remoteChapter, key);
    if (names.isEmpty) {
      throw const FormatException('MangaDex chapter has no readable pages');
    }
    final pathKind = useDataSaver ? 'data-saver' : 'data';
    final assets = <PageAsset>[];
    for (var index = 0; index < names.length; index++) {
      final filename = names[index];
      assets.add(
        PageAsset(
          pageId: 'page-${index + 1}',
          chapterId: chapterId,
          index: index,
          uri: baseUrl.replace(
            path: '${baseUrl.path}/$pathKind/$hash/$filename'
                .replaceAll('//', '/'),
          ),
          contentKindHint: _contentKind(filename),
        ),
      );
    }
    final chapterNumber = _optionalString(attributes['chapter']);
    final chapter = Chapter(
      chapterId: chapterId,
      comicId: comicId,
      title: _chapterTitle(
        chapterNumber,
        _optionalString(attributes['title']),
      ),
      sequence: _chapterSequence(chapterNumber, 0),
      pageCount: assets.length,
      publishedAt: _optionalDateTime(attributes['publishAt']),
      updatedAt: _optionalDateTime(attributes['updatedAt']),
      sourceRevision: hash,
    );
    return ChapterManifest(
      sourceId: sourceId,
      comicId: comicId,
      chapter: chapter,
      pages: assets,
      readingDirection: comic.readingDirection,
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) =>
      _readResource(uri, maxBytes: _maxResourceBytes);

  Future<Uint8List> _readResource(
    Uri uri, {
    required int maxBytes,
  }) async {
    for (var attempt = 1; attempt <= maxNetworkAttempts; attempt++) {
      try {
        final response = await _transport.open(uri);
        final declaredLength = response.totalLength;
        if (declaredLength != null && declaredLength > maxBytes) {
          await response.discard();
          throw Failure(
            code: ErrorCode.source,
            message: 'source response exceeds $maxBytes bytes: $uri',
          );
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.bytes) {
          if (builder.length + chunk.length > maxBytes) {
            throw Failure(
              code: ErrorCode.source,
              message: 'source response exceeds $maxBytes bytes: $uri',
            );
          }
          builder.add(chunk);
        }
        return builder.takeBytes();
      } on Failure catch (failure) {
        if (failure.code != ErrorCode.network ||
            attempt >= maxNetworkAttempts) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }
    throw StateError('unreachable MangaDex network retry state');
  }

  Future<Comic> _loadComicIdentity(String comicId) async {
    final payload = await _getObject(
      _api('/manga/$comicId', <String, Object>{
        'includes[]': const <String>['cover_art', 'author', 'artist'],
      }),
    );
    final comic = _parseComic(_requiredObject(payload, 'data'));
    _comicCache[comicId] = comic;
    return comic;
  }

  Comic _parseComic(Map<String, Object?> data) {
    final attributes = _requiredObject(data, 'attributes');
    final comicId = _requiredString(data, 'id');
    final originalLanguage = _optionalString(attributes['originalLanguage']);
    return Comic(
      comicId: comicId,
      sourceId: sourceId,
      title: _localizedText(attributes['title'], translatedLanguage) ?? comicId,
      authors: _relationshipNames(data),
      coverUri: _coverUri(data, comicId),
      description: _localizedText(
        attributes['description'],
        translatedLanguage,
      ),
      readingDirection:
          originalLanguage == 'ja' ? ReadingDirection.rtl : ReadingDirection.ltr,
      createdAt: _optionalDateTime(attributes['createdAt']),
      updatedAt: _optionalDateTime(attributes['updatedAt']),
    );
  }

  SourceComicSummary _parseSummary(Map<String, Object?> data) {
    final attributes = _requiredObject(data, 'attributes');
    final comicId = _requiredString(data, 'id');
    return SourceComicSummary(
      sourceId: sourceId,
      comicId: comicId,
      title: _localizedText(attributes['title'], translatedLanguage) ?? comicId,
      authors: _relationshipNames(data),
      coverUri: _coverUri(data, comicId),
      description: _localizedText(
        attributes['description'],
        translatedLanguage,
      ),
      contentRating: _contentRating(
        _optionalString(attributes['contentRating']),
      ),
    );
  }

  Uri? _coverUri(Map<String, Object?> data, String comicId) {
    final relationships = _objectList(data, 'relationships');
    for (final relationship in relationships) {
      if (_optionalString(relationship['type']) != 'cover_art') {
        continue;
      }
      final attributes = relationship['attributes'];
      if (attributes is! Map) {
        continue;
      }
      final filename = _optionalString(attributes['fileName']);
      if (filename == null) {
        continue;
      }
      return _uploadsRoot.replace(path: '/covers/$comicId/$filename.256.jpg');
    }
    return null;
  }

  List<String> _relationshipNames(Map<String, Object?> data) {
    final names = <String>{};
    for (final relationship in _objectList(data, 'relationships')) {
      final type = _optionalString(relationship['type']);
      if (type != 'author' && type != 'artist') {
        continue;
      }
      final attributes = relationship['attributes'];
      if (attributes is! Map) {
        continue;
      }
      final name = _optionalString(attributes['name']);
      if (name != null) {
        names.add(name);
      }
    }
    return names.toList(growable: false);
  }

  Future<Map<String, Object?>> _getObject(Uri uri) async {
    final bytes = await _readResource(uri, maxBytes: _maxMetadataBytes);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw FormatException('MangaDex response root must be an object: $uri');
    }
    return Map<String, Object?>.from(decoded);
  }

  Uri _api(String path, [Map<String, Object>? parameters]) => _apiRoot.replace(
        path: path,
        queryParameters: parameters,
      );
}

Map<String, Object?> _requiredObject(
  Map<String, Object?> value,
  String key,
) {
  final child = value[key];
  if (child is! Map) {
    throw FormatException('$key must be an object');
  }
  return Map<String, Object?>.from(child);
}

List<Map<String, Object?>> _objectList(
  Map<String, Object?> value,
  String key,
) {
  final raw = value[key];
  if (raw is! List) {
    throw FormatException('$key must be a list');
  }
  return raw.map((entry) {
    if (entry is! Map) {
      throw FormatException('$key entries must be objects');
    }
    return Map<String, Object?>.from(entry);
  }).toList(growable: false);
}

List<String> _stringList(Map<String, Object?> value, String key) {
  final raw = value[key];
  if (raw is! List || raw.any((entry) => entry is! String)) {
    throw FormatException('$key must be a string list');
  }
  return raw.cast<String>();
}

String _requiredString(Map<String, Object?> value, String key) {
  final result = _optionalString(value[key]);
  if (result == null) {
    throw FormatException('$key must be a non-empty string');
  }
  return result;
}

String? _optionalString(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}

int? _optionalInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}

DateTime? _optionalDateTime(Object? value) {
  final source = _optionalString(value);
  return source == null ? null : DateTime.tryParse(source)?.toUtc();
}

String? _localizedText(Object? value, String preferredLanguage) {
  if (value is! Map) {
    return null;
  }
  final map = Map<String, Object?>.from(value);
  for (final language in <String>[
    preferredLanguage,
    'en',
    'ja-ro',
    'zh',
    'zh-hk',
  ]) {
    final selected = _optionalString(map[language]);
    if (selected != null) {
      return selected;
    }
  }
  for (final candidate in map.values) {
    final selected = _optionalString(candidate);
    if (selected != null) {
      return selected;
    }
  }
  return null;
}

String? _relationshipId(Map<String, Object?> data, String type) {
  for (final relationship in _objectList(data, 'relationships')) {
    if (_optionalString(relationship['type']) == type) {
      return _optionalString(relationship['id']);
    }
  }
  return null;
}

String _chapterTitle(String? number, String? title) {
  if (number != null && title != null) {
    return 'Ch. $number · $title';
  }
  if (number != null) {
    return 'Ch. $number';
  }
  return title ?? 'Chapter';
}

int _chapterSequence(String? number, int fallback) {
  final parsed = number == null ? null : double.tryParse(number);
  return parsed == null ? fallback : (parsed * 1000).round();
}

ContentKindHint _contentKind(String filename) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return ContentKindHint.jpeg;
  }
  if (lower.endsWith('.png')) {
    return ContentKindHint.png;
  }
  if (lower.endsWith('.webp')) {
    return ContentKindHint.webp;
  }
  if (lower.endsWith('.gif')) {
    return ContentKindHint.gif;
  }
  if (lower.endsWith('.avif')) {
    return ContentKindHint.avif;
  }
  return ContentKindHint.unknown;
}

SourceContentRating _contentRating(String? value) => switch (value) {
      'suggestive' => SourceContentRating.suggestive,
      'erotica' => SourceContentRating.erotica,
      'pornographic' => SourceContentRating.pornographic,
      _ => SourceContentRating.safe,
    };
