enum ComicSourceKind { local, remote }

enum LibrarySortMode { recent, title, pageCount, custom }

final class ComicSourcePreference {
  const ComicSourcePreference({
    required this.sourceId,
    required this.enabled,
    required this.sortOrder,
    required this.updatedAt,
  });

  factory ComicSourcePreference.defaults({
    required String sourceId,
    int sortOrder = 0,
  }) => ComicSourcePreference(
        sourceId: sourceId,
        enabled: true,
        sortOrder: sortOrder,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  final String sourceId;
  final bool enabled;
  final int sortOrder;
  final DateTime updatedAt;

  ComicSourcePreference copyWith({
    bool? enabled,
    int? sortOrder,
    DateTime? updatedAt,
  }) => ComicSourcePreference(
        sourceId: sourceId,
        enabled: enabled ?? this.enabled,
        sortOrder: sortOrder ?? this.sortOrder,
        updatedAt: (updatedAt ?? this.updatedAt).toUtc(),
      );

  Map<String, Object> toJson() => <String, Object>{
        'sourceId': sourceId,
        'enabled': enabled,
        'sortOrder': sortOrder,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ComicSourcePreference.fromJson(Map<String, Object?> json) =>
      ComicSourcePreference(
        sourceId: _requiredString(json, 'sourceId'),
        enabled: _requiredBool(json, 'enabled'),
        sortOrder: _requiredInt(json, 'sortOrder'),
        updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')),
      );
}

final class LibraryCategory {
  const LibraryCategory({
    required this.categoryId,
    required this.name,
    required this.sortOrder,
    required this.createdAt,
  });

  final String categoryId;
  final String name;
  final int sortOrder;
  final DateTime createdAt;

  LibraryCategory copyWith({
    String? name,
    int? sortOrder,
  }) {
    return LibraryCategory(
      categoryId: categoryId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'categoryId': categoryId,
        'name': name,
        'sortOrder': sortOrder,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory LibraryCategory.fromJson(Map<String, Object?> json) {
    return LibraryCategory(
      categoryId: _requiredString(json, 'categoryId'),
      name: _requiredString(json, 'name'),
      sortOrder: _requiredInt(json, 'sortOrder'),
      createdAt: DateTime.parse(_requiredString(json, 'createdAt')),
    );
  }
}

final class ComicPreference {
  ComicPreference({
    required this.sourceId,
    required this.comicId,
    required this.sourceKind,
    required this.inShelf,
    required this.liked,
    required this.collected,
    required Iterable<String> categoryIds,
    required this.customOrder,
    required this.updatedAt,
  }) : categoryIds = Set<String>.unmodifiable(categoryIds) {
    if (sourceId.trim().isEmpty || comicId.trim().isEmpty) {
      throw ArgumentError('comic preference identity must be non-empty');
    }
  }

  factory ComicPreference.defaults({
    required String sourceId,
    required String comicId,
    ComicSourceKind sourceKind = ComicSourceKind.local,
    int customOrder = 0,
  }) {
    return ComicPreference(
      sourceId: sourceId,
      comicId: comicId,
      sourceKind: sourceKind,
      inShelf: true,
      liked: false,
      collected: false,
      categoryIds: const <String>{},
      customOrder: customOrder,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  final String sourceId;
  final String comicId;
  final ComicSourceKind sourceKind;
  final bool inShelf;
  final bool liked;
  final bool collected;
  final Set<String> categoryIds;
  final int customOrder;
  final DateTime updatedAt;

  String get identity => '$sourceId\u0000$comicId';

  ComicPreference copyWith({
    ComicSourceKind? sourceKind,
    bool? inShelf,
    bool? liked,
    bool? collected,
    Iterable<String>? categoryIds,
    int? customOrder,
    DateTime? updatedAt,
  }) {
    return ComicPreference(
      sourceId: sourceId,
      comicId: comicId,
      sourceKind: sourceKind ?? this.sourceKind,
      inShelf: inShelf ?? this.inShelf,
      liked: liked ?? this.liked,
      collected: collected ?? this.collected,
      categoryIds: categoryIds ?? this.categoryIds,
      customOrder: customOrder ?? this.customOrder,
      updatedAt: (updatedAt ?? this.updatedAt).toUtc(),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'sourceId': sourceId,
        'comicId': comicId,
        'sourceKind': sourceKind.name,
        'inShelf': inShelf,
        'liked': liked,
        'collected': collected,
        'categoryIds': categoryIds.toList(growable: false)..sort(),
        'customOrder': customOrder,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ComicPreference.fromJson(
    Map<String, Object?> json, {
    String? fallbackSourceId,
  }) {
    final rawCategoryIds = json['categoryIds'];
    if (rawCategoryIds is! List<Object?> ||
        rawCategoryIds.any((value) => value is! String)) {
      throw const FormatException('categoryIds must be a string list');
    }
    final sourceId = (json['sourceId'] as String?) ?? fallbackSourceId;
    if (sourceId == null || sourceId.trim().isEmpty) {
      throw const FormatException('sourceId must be a non-empty string');
    }
    return ComicPreference(
      sourceId: sourceId,
      comicId: _requiredString(json, 'comicId'),
      sourceKind: ComicSourceKind.values.byName(
        _requiredString(json, 'sourceKind'),
      ),
      inShelf: _requiredBool(json, 'inShelf'),
      liked: _requiredBool(json, 'liked'),
      collected: _requiredBool(json, 'collected'),
      categoryIds: rawCategoryIds.cast<String>(),
      customOrder: _requiredInt(json, 'customOrder'),
      updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')),
    );
  }
}

final class ChapterReadState {
  const ChapterReadState({
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.isRead,
    required this.updatedAt,
  });

  final String sourceId;
  final String comicId;
  final String chapterId;
  final bool isRead;
  final DateTime updatedAt;

  String get identity => '$sourceId\u0000$chapterId';

  Map<String, Object> toJson() => <String, Object>{
        'sourceId': sourceId,
        'comicId': comicId,
        'chapterId': chapterId,
        'isRead': isRead,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ChapterReadState.fromJson(
    Map<String, Object?> json, {
    String? fallbackSourceId,
  }) {
    final sourceId = (json['sourceId'] as String?) ?? fallbackSourceId;
    if (sourceId == null || sourceId.trim().isEmpty) {
      throw const FormatException('sourceId must be a non-empty string');
    }
    return ChapterReadState(
      sourceId: sourceId,
      comicId: _requiredString(json, 'comicId'),
      chapterId: _requiredString(json, 'chapterId'),
      isRead: _requiredBool(json, 'isRead'),
      updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')),
    );
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('$key must be an integer');
  }
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('$key must be a boolean');
  }
  return value;
}
