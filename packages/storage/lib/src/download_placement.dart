import 'dart:convert';

/// Placement mode chosen for a comic download task.
enum DownloadPlacementMode {
  /// Reuses existing artifacts and bindings in the target directory and
  /// only downloads missing pages.
  incremental,

  /// Replaces the export binding and updates directory ownership to the
  /// current comic version.
  overwrite,

  /// Assigns a newly allocated unique export directory.
  createNew,
}

/// Page ordering used when formatting page filenames within structured directories.
enum ComicPageOrder {
  /// Unresolved export-layout intent. It must be frozen to [chronological] or
  /// [origin] before the first structured page is materialized.
  auto,

  /// True chronological order (oldest page = 001, newest = N), appending
  /// prepended updates to the end without renaming existing pages.
  chronological,

  /// Gallery manifest order (page 1 of gallery = 001).
  origin,
}

/// Sparse durable mapping from one logical page to its user-visible export
/// ordinal. Bindings are created only for a comic/chapter that actually enters
/// export materialization; unopened versions never receive per-page rows.
final class ExportPageBinding {
  const ExportPageBinding({
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.pageId,
    required this.logicalIndex,
    required this.exportOrdinal,
    this.placementGeneration = 0,
  });

  final String sourceId;
  final String comicId;
  final String chapterId;
  final String pageId;
  final int logicalIndex;
  final int exportOrdinal;
  final int placementGeneration;

  String get ownerKey => '$sourceId\u0000$comicId\u0000$chapterId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExportPageBinding &&
          sourceId == other.sourceId &&
          comicId == other.comicId &&
          chapterId == other.chapterId &&
          pageId == other.pageId &&
          logicalIndex == other.logicalIndex &&
          exportOrdinal == other.exportOrdinal &&
          placementGeneration == other.placementGeneration;

  @override
  int get hashCode => Object.hash(
        sourceId,
        comicId,
        chapterId,
        pageId,
        logicalIndex,
        exportOrdinal,
        placementGeneration,
      );
}

/// Immutable placement contract for a comic download task, defining its
/// intended storage root, export directory, ownership, and conflict mode.
final class DownloadPlacement {
  const DownloadPlacement({
    required this.placementId,
    required this.sourceId,
    required this.comicId,
    required this.comicTitle,
    required this.mode,
    required this.relativeDirectory,
    this.storageRootId = 'default',
    this.comicFamilyId,
    this.observedOwnerKey,
    this.generation = 0,
    this.fingerprint,
    this.pageOrder = ComicPageOrder.auto,
    required this.createdAt,
    required this.updatedAt,
  });

  final String placementId;
  final String sourceId;
  final String comicId;
  final String comicTitle;
  final DownloadPlacementMode mode;
  final String relativeDirectory;
  final String storageRootId;
  final String? comicFamilyId;
  final String? observedOwnerKey;

  /// Monotonic owner-manifest generation used by compare-and-swap commits.
  final int generation;

  /// Fingerprint of the last committed structured ownership manifest.
  final String? fingerprint;
  final ComicPageOrder pageOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get ownerKey => '$sourceId\u0000$comicId';

  DownloadPlacement copyWith({
    String? placementId,
    String? sourceId,
    String? comicId,
    String? comicTitle,
    DownloadPlacementMode? mode,
    String? relativeDirectory,
    String? storageRootId,
    String? comicFamilyId,
    String? observedOwnerKey,
    int? generation,
    String? fingerprint,
    ComicPageOrder? pageOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DownloadPlacement(
      placementId: placementId ?? this.placementId,
      sourceId: sourceId ?? this.sourceId,
      comicId: comicId ?? this.comicId,
      comicTitle: comicTitle ?? this.comicTitle,
      mode: mode ?? this.mode,
      relativeDirectory: relativeDirectory ?? this.relativeDirectory,
      storageRootId: storageRootId ?? this.storageRootId,
      comicFamilyId: comicFamilyId ?? this.comicFamilyId,
      observedOwnerKey: observedOwnerKey ?? this.observedOwnerKey,
      generation: generation ?? this.generation,
      fingerprint: fingerprint ?? this.fingerprint,
      pageOrder: pageOrder ?? this.pageOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'placementId': placementId,
        'sourceId': sourceId,
        'comicId': comicId,
        'comicTitle': comicTitle,
        'mode': mode.name,
        'relativeDirectory': relativeDirectory,
        'storageRootId': storageRootId,
        if (comicFamilyId != null) 'comicFamilyId': comicFamilyId,
        if (observedOwnerKey != null) 'observedOwnerKey': observedOwnerKey,
        'generation': generation,
        if (fingerprint != null) 'fingerprint': fingerprint,
        'pageOrder': pageOrder.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory DownloadPlacement.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    final mode = DownloadPlacementMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => DownloadPlacementMode.incremental,
    );
    final orderName = json['pageOrder'] as String?;
    final pageOrder = ComicPageOrder.values.firstWhere(
      (p) => p.name == orderName,
      orElse: () => ComicPageOrder.auto,
    );
    return DownloadPlacement(
      placementId: (json['placementId'] as String?) ?? '',
      sourceId: (json['sourceId'] as String?) ?? '',
      comicId: (json['comicId'] as String?) ?? '',
      comicTitle: (json['comicTitle'] as String?) ?? '',
      mode: mode,
      relativeDirectory: (json['relativeDirectory'] as String?) ?? '',
      storageRootId: (json['storageRootId'] as String?) ?? 'default',
      comicFamilyId: json['comicFamilyId'] as String?,
      observedOwnerKey: json['observedOwnerKey'] as String?,
      generation: (json['generation'] as num?)?.toInt() ?? 0,
      fingerprint: json['fingerprint'] as String?,
      pageOrder: pageOrder,
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String)?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String)?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static DownloadPlacement? decode(String content) {
    try {
      final map = jsonDecode(content);
      if (map is Map<String, dynamic>) {
        return DownloadPlacement.fromJson(map);
      }
      if (map is Map) {
        return DownloadPlacement.fromJson(map.cast<String, dynamic>());
      }
    } on Object {}
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadPlacement &&
          runtimeType == other.runtimeType &&
          placementId == other.placementId &&
          sourceId == other.sourceId &&
          comicId == other.comicId &&
          comicTitle == other.comicTitle &&
          mode == other.mode &&
          relativeDirectory == other.relativeDirectory &&
          storageRootId == other.storageRootId &&
          comicFamilyId == other.comicFamilyId &&
          observedOwnerKey == other.observedOwnerKey &&
          generation == other.generation &&
          fingerprint == other.fingerprint &&
          pageOrder == other.pageOrder;

  @override
  int get hashCode => Object.hash(
        placementId,
        sourceId,
        comicId,
        comicTitle,
        mode,
        relativeDirectory,
        storageRootId,
        comicFamilyId,
        observedOwnerKey,
        generation,
        fingerprint,
        pageOrder,
      );

  @override
  String toString() =>
      'DownloadPlacement($placementId, $sourceId:$comicId, mode=${mode.name}, dir=$relativeDirectory)';
}
