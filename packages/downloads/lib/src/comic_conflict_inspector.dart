import 'dart:convert';
import 'dart:io';

import 'package:storage/storage.dart';

import 'artifact_bytes.dart';

/// Represents the version relationship between a download target and an existing local folder.
enum ComicVersionRelationKind {
  /// Incoming download is a newer version (successor) of the existing local download.
  incomingIsNewer,

  /// Existing local download is already a newer version (successor) of the incoming download.
  existingIsNewer,

  /// Exact same version (same sourceId and comicId).
  sameVersion,

  /// Title-matched or unknown version relation.
  unknown,
}

/// Represents a candidate comic directory found in the target download root.
final class ComicFolderCandidate {
  const ComicFolderCandidate({
    required this.directoryPath,
    required this.folderName,
    this.manifest,
    this.hasManifestFile = false,
    required this.isExactMatch,
    required this.isTitleMatch,
    required this.chapterCount,
    required this.existingPageFilesCount,
    this.versionRelation = ComicVersionRelationKind.unknown,
  });

  final String directoryPath;
  final String folderName;
  final ComicFolderManifest? manifest;

  /// Whether a `.zic.json` entry exists, including when its contents are
  /// malformed and therefore cannot be decoded as [manifest].
  final bool hasManifestFile;

  /// Whether this folder belongs to the exact same (sourceId, comicId).
  final bool isExactMatch;

  /// Whether this folder shares the same comicTitle but belongs to a different
  /// source or comicId (or has no manifest).
  final bool isTitleMatch;

  final int chapterCount;
  final int existingPageFilesCount;

  final ComicVersionRelationKind versionRelation;

  /// Confidence score between 0.0 and 1.0.
  double get confidenceScore {
    if (isExactMatch) return 1.0;
    if (versionRelation == ComicVersionRelationKind.incomingIsNewer ||
        versionRelation == ComicVersionRelationKind.existingIsNewer) {
      return 0.95;
    }
    if (manifest != null && isTitleMatch) return 0.85;
    if (isTitleMatch) return 0.70;
    return 0.50;
  }

  /// Human-readable confidence description.
  String get confidenceLabel {
    if (isExactMatch) return '完全匹配 (同源同ID)';
    if (versionRelation == ComicVersionRelationKind.incomingIsNewer) {
      return '历史版本 (可更新替换)';
    }
    if (versionRelation == ComicVersionRelationKind.existingIsNewer) {
      return '较新版本 (已存在)';
    }
    if (manifest?.sourceDisplayName != null &&
        manifest!.sourceDisplayName!.isNotEmpty) {
      return '同名候选 (${manifest!.sourceDisplayName})';
    }
    if (isTitleMatch) return '同名目录';
    return '相似目录';
  }

  bool get hasExistingContent =>
      existingPageFilesCount > 0 ||
      chapterCount > 0 ||
      manifest != null ||
      hasManifestFile;
}

/// Normalizes a comic title for flexible similarity comparison by removing
/// tags, brackets, and punctuation.
String normalizeComicTitleForComparison(String title) {
  var s = title
      .replaceAll(RegExp(r'\[.*?\]'), ' ')
      .replaceAll(RegExp(r'\(.*?\)'), ' ')
      .replaceAll(RegExp(r'【.*?】'), ' ')
      .replaceAll(RegExp(r'（.*?）'), ' ')
      .replaceAll(RegExp(r'[\/\\:\*\?"<>\|\x00-\x1F\x7F_]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
  return s.isEmpty ? title.trim().toLowerCase() : s;
}

/// Checks if [folderName] is a plausible candidate matching [cleanTitle].
bool isFolderCandidateForTitle({
  required String folderName,
  required String cleanTitle,
}) {
  final f = folderName.trim().toLowerCase();
  final t = cleanTitle.trim().toLowerCase();
  if (f.isEmpty || t.isEmpty) return false;
  if (f == t) return true;
  if (f.startsWith(t)) return true;
  if (f.contains(t) || t.contains(f)) return true;
  final nf = normalizeComicTitleForComparison(f);
  final nt = normalizeComicTitleForComparison(t);
  if (nf.isNotEmpty && nt.isNotEmpty) {
    if (nf == nt || nf.startsWith(nt) || nf.contains(nt) || nt.contains(nf)) {
      return true;
    }
  }
  return false;
}

/// Report produced prior to downloading a comic, highlighting existing folders
/// and conflict candidates.
final class ComicConflictReport {
  const ComicConflictReport({
    required this.candidates,
    required this.hasDirectExactMatch,
    required this.hasTitleConflicts,
    required this.recommendedDirectoryName,
  });

  final List<ComicFolderCandidate> candidates;
  final bool hasDirectExactMatch;
  final bool hasTitleConflicts;
  final String recommendedDirectoryName;

  /// Returns true if there are existing files on disk in any matching candidate folder.
  bool get hasExistingFiles =>
      candidates.any((c) => c.hasExistingContent);

  ComicFolderCandidate? get matchingCandidate =>
      candidates.where((c) => c.isExactMatch).firstOrNull ??
      candidates.firstOrNull;
}

/// Inspects [rootDirectory] on the POSIX filesystem to find matching comic
/// folders and potential title/source conflicts.
Future<ComicConflictReport> inspectPosixComicConflicts({
  required String rootDirectory,
  required String sourceId,
  String? sourceDisplayName,
  required String comicId,
  required String comicTitle,
  Set<String>? knownPredecessorComicIds,
  Set<String>? knownSuccessorComicIds,
  Map<String, ({String sourceId, String comicId})>? knownDirectoryOwners,
}) async {
  final root = Directory(rootDirectory);
  if (!await root.exists()) {
    final cleanName = buildComicDirectoryName(comicTitle: comicTitle);
    return ComicConflictReport(
      candidates: const <ComicFolderCandidate>[],
      hasDirectExactMatch: false,
      hasTitleConflicts: false,
      recommendedDirectoryName: cleanName,
    );
  }

  final cleanTitle = sanitizePathSegment(comicTitle, fallback: 'comic');
  final candidates = <ComicFolderCandidate>[];

  await for (final entity in root.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final folderName = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (!isFolderCandidateForTitle(folderName: folderName, cleanTitle: cleanTitle)) {
      continue;
    }

    // Found matching folder candidate. Check for .zic.json manifest.
    ComicFolderManifest? manifest;
    final manifestFile = File(
      '${entity.path}${Platform.pathSeparator}$comicManifestFileName',
    );
    final hasManifestFile = await manifestFile.exists();
    if (hasManifestFile) {
      try {
        final content = await manifestFile.readAsString();
        manifest = ComicFolderManifest.decode(content);
      } on Object {
        // Ignored.
      }
    }

    final knownOwner = knownDirectoryOwners?[folderName];
    final ownerSourceId = manifest?.sourceId ?? knownOwner?.sourceId;
    final ownerComicId = manifest?.comicId ?? knownOwner?.comicId;

    final isExactMatch = ownerSourceId == sourceId && ownerComicId == comicId;

    ComicVersionRelationKind versionRelation;
    if (isExactMatch) {
      versionRelation = ComicVersionRelationKind.sameVersion;
    } else if (ownerComicId != null &&
        (knownPredecessorComicIds?.contains(ownerComicId) == true ||
            (ownerSourceId == sourceId &&
                knownPredecessorComicIds?.contains(ownerComicId) == true))) {
      versionRelation = ComicVersionRelationKind.incomingIsNewer;
    } else if (ownerComicId != null &&
        (knownSuccessorComicIds?.contains(ownerComicId) == true ||
            (ownerSourceId == sourceId &&
                knownSuccessorComicIds?.contains(ownerComicId) == true))) {
      versionRelation = ComicVersionRelationKind.existingIsNewer;
    } else {
      versionRelation = ComicVersionRelationKind.unknown;
    }

    var chapterCount = 0;
    var pageCount = 0;
    try {
      await for (final sub in entity.list(followLinks: false)) {
        if (sub is Directory) {
          chapterCount++;
          await for (final page in sub.list(followLinks: false)) {
            if (page is File &&
                !page.path.endsWith(comicManifestFileName) &&
                !page.path.endsWith('cache.sqlite')) {
              pageCount++;
            }
          }
        } else if (sub is File &&
            !sub.path.endsWith(comicManifestFileName) &&
            !sub.path.endsWith('cache.sqlite')) {
          pageCount++;
        }
      }
    } on Object {
      // Ignored.
    }

    candidates.add(
      ComicFolderCandidate(
        directoryPath: entity.path,
        folderName: folderName,
        manifest: manifest,
        hasManifestFile: hasManifestFile,
        isExactMatch: isExactMatch,
        isTitleMatch: !isExactMatch,
        chapterCount: chapterCount > 0
            ? chapterCount
            : (manifest?.chapters.length ?? 0),
        existingPageFilesCount: pageCount,
        versionRelation: versionRelation,
      ),
    );
  }

  final hasDirectExactMatch = candidates.any((c) => c.isExactMatch);
  final hasTitleConflicts = candidates.any((c) => c.isTitleMatch);

  final cleanName = buildComicDirectoryName(comicTitle: comicTitle);
  final cleanCandidate = candidates.where((c) => c.folderName == cleanName).firstOrNull;
  final cleanOccupiedByOther = cleanCandidate != null &&
      cleanCandidate.hasExistingContent &&
      !cleanCandidate.isExactMatch;

  String recommendedDirectory;
  if (!cleanOccupiedByOther || hasDirectExactMatch) {
    recommendedDirectory = cleanName;
  } else {
    final suffix = sourceDisplayName ?? sourceId;
    recommendedDirectory = buildComicDirectoryName(
      comicTitle: comicTitle,
      conflictSourceSuffix: suffix,
    );
    var sequence = 2;
    while (candidates.any((c) => c.folderName == recommendedDirectory)) {
      recommendedDirectory = buildComicDirectoryName(
        comicTitle: comicTitle,
        conflictSourceSuffix: '$suffix $sequence',
      );
      sequence++;
    }
  }

  return ComicConflictReport(
    candidates: List<ComicFolderCandidate>.unmodifiable(candidates),
    hasDirectExactMatch: hasDirectExactMatch,
    hasTitleConflicts: hasTitleConflicts,
    recommendedDirectoryName: recommendedDirectory,
  );
}

/// Inspects target SAF document tree to find matching comic folders and potential
/// title/source conflicts.
Future<ComicConflictReport> inspectSafComicConflicts({
  required SafTreeIo safIo,
  required String safTreeUri,
  required String sourceId,
  String? sourceDisplayName,
  required String comicId,
  required String comicTitle,
  Set<String>? knownPredecessorComicIds,
  Set<String>? knownSuccessorComicIds,
  Map<String, ({String sourceId, String comicId})>? knownDirectoryOwners,
}) async {
  final cleanName = buildComicDirectoryName(comicTitle: comicTitle);
  final candidates = <ComicFolderCandidate>[];

  final rootEntries = await safIo.list('');
  final folderNames = <String>{};

  if (rootEntries.isNotEmpty) {
    for (final entry in rootEntries) {
      if (entry.isDirectory &&
          isFolderCandidateForTitle(
            folderName: entry.name,
            cleanTitle: cleanName,
          )) {
        folderNames.add(entry.name);
      }
    }
  } else {
    folderNames.addAll(<String>{
      cleanName,
      if (sourceDisplayName != null && sourceDisplayName.isNotEmpty)
        buildComicDirectoryName(
          comicTitle: comicTitle,
          conflictSourceSuffix: sourceDisplayName,
        ),
      if (sourceId.isNotEmpty && sourceId != sourceDisplayName)
        buildComicDirectoryName(
          comicTitle: comicTitle,
          conflictSourceSuffix: sourceId,
        ),
    });
  }

  for (final folderName in folderNames) {
    final manifestPath = '$folderName/$comicManifestFileName';
    ComicFolderManifest? manifest;
    var exists = false;
    var hasManifestFile = false;
    var pageCount = 0;
    var chapterCount = 0;

    if (await safIo.exists(manifestPath)) {
      exists = true;
      hasManifestFile = true;
      try {
        final handle = await safIo.open(manifestPath, mode: SafWriteMode.read);
        if (handle != null) {
          final len = await safIo.length(handle) ?? 0;
          final bytes = await safIo.read(handle, len);
          await safIo.close(handle);
          manifest = ComicFolderManifest.decode(utf8.decode(bytes));
        }
      } catch (_) {}
    }

    if (rootEntries.isNotEmpty) {
      final subEntries = await safIo.list(folderName);
      exists = true;
      for (final sub in subEntries) {
        if (sub.isDirectory) {
          chapterCount++;
          final chapterEntries = await safIo.list('$folderName/${sub.name}');
          for (final page in chapterEntries) {
            if (!page.isDirectory &&
                !page.name.endsWith(comicManifestFileName) &&
                !page.name.endsWith('cache.sqlite')) {
              pageCount++;
            }
          }
        } else if (!sub.name.endsWith(comicManifestFileName) &&
            !sub.name.endsWith('cache.sqlite')) {
          pageCount++;
        }
      }
    } else if (await safIo.exists(folderName)) {
      exists = true;
    }

    if (exists) {
      final knownOwner = knownDirectoryOwners?[folderName];
      final ownerSourceId = manifest?.sourceId ?? knownOwner?.sourceId;
      final ownerComicId = manifest?.comicId ?? knownOwner?.comicId;

      final isExactMatch = ownerSourceId == sourceId && ownerComicId == comicId;
      ComicVersionRelationKind versionRelation;
      if (isExactMatch) {
        versionRelation = ComicVersionRelationKind.sameVersion;
      } else if (ownerComicId != null &&
          (knownPredecessorComicIds?.contains(ownerComicId) == true ||
              (ownerSourceId == sourceId &&
                  knownPredecessorComicIds?.contains(ownerComicId) == true))) {
        versionRelation = ComicVersionRelationKind.incomingIsNewer;
      } else if (ownerComicId != null &&
          (knownSuccessorComicIds?.contains(ownerComicId) == true ||
              (ownerSourceId == sourceId &&
                  knownSuccessorComicIds?.contains(ownerComicId) == true))) {
        versionRelation = ComicVersionRelationKind.existingIsNewer;
      } else {
        versionRelation = ComicVersionRelationKind.unknown;
      }
      candidates.add(
        ComicFolderCandidate(
          directoryPath: 'saf://$safTreeUri/$folderName',
          folderName: folderName,
          manifest: manifest,
          hasManifestFile: hasManifestFile,
          isExactMatch: isExactMatch,
          isTitleMatch: !isExactMatch,
          chapterCount: chapterCount > 0
              ? chapterCount
              : (manifest?.chapters.length ?? 0),
          existingPageFilesCount: pageCount,
          versionRelation: versionRelation,
        ),
      );
    }
  }

  final hasDirectExactMatch = candidates.any((c) => c.isExactMatch);
  final hasTitleConflicts = candidates.any((c) => c.isTitleMatch);

  final cleanCandidate = candidates.where((c) => c.folderName == cleanName).firstOrNull;
  final cleanOccupiedByOther = cleanCandidate != null &&
      cleanCandidate.hasExistingContent &&
      !cleanCandidate.isExactMatch;

  String recommendedDirectory;
  if (!cleanOccupiedByOther || hasDirectExactMatch) {
    recommendedDirectory = cleanName;
  } else {
    final suffix = sourceDisplayName ?? sourceId;
    recommendedDirectory = buildComicDirectoryName(
      comicTitle: comicTitle,
      conflictSourceSuffix: suffix,
    );
    var sequence = 2;
    while (candidates.any((c) => c.folderName == recommendedDirectory)) {
      recommendedDirectory = buildComicDirectoryName(
        comicTitle: comicTitle,
        conflictSourceSuffix: '$suffix $sequence',
      );
      sequence++;
    }
  }

  return ComicConflictReport(
    candidates: List<ComicFolderCandidate>.unmodifiable(candidates),
    hasDirectExactMatch: hasDirectExactMatch,
    hasTitleConflicts: hasTitleConflicts,
    recommendedDirectoryName: recommendedDirectory,
  );
}
