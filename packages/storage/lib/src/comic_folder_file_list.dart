/// Portable file metadata for recovery/import. A manifest is descriptive:
/// bytes must be independently verified before granting artifact authority.
final class ComicPageFile {
  const ComicPageFile({required this.logicalIndex, required this.pageId,
    required this.fileName, required this.bytes, required this.checksum,
    required this.checksumAlgorithm});

  final int logicalIndex;
  final String pageId;
  final String fileName;
  final int bytes;
  final String checksum;
  final String checksumAlgorithm;

  Map<String, Object> toJson() => {
    'index': logicalIndex, 'pageId': pageId, 'file': fileName, 'bytes': bytes,
    'checksum': checksum, 'checksumAlgorithm': checksumAlgorithm,
  };

  factory ComicPageFile.fromJson(Map<String, dynamic> json) {
    final file = json['file'];
    final index = json['index'];
    final bytes = json['bytes'];
    final pageId = json['pageId'];
    final checksum = json['checksum'];
    final algorithm = json['checksumAlgorithm'];
    if (file is! String || file.isEmpty || file == '.' || file == '..' ||
        RegExp(r'[\\/:\x00-\x1f\x7f]').hasMatch(file) || file.startsWith('.') ||
        index is! int || index < 0 || bytes is! int || bytes <= 0 ||
        pageId is! String || pageId.isEmpty ||
        checksum is! String || checksum.trim().isEmpty ||
        algorithm is! String || algorithm.trim().isEmpty) {
      throw const FormatException('invalid comic page file metadata');
    }
    return ComicPageFile(logicalIndex: index, pageId: pageId, fileName: file,
      bytes: bytes, checksum: checksum, checksumAlgorithm: algorithm);
  }
}

final class ComicChapterFileList {
  const ComicChapterFileList({required this.sourceRevision,
    required this.pageCount, required this.pages});

  final String sourceRevision;
  final int pageCount;
  final List<ComicPageFile> pages;

  Map<String, Object> toJson() => {
    'sourceRevision': sourceRevision, 'pageCount': pageCount,
    'pages': [for (final page in pages) page.toJson()],
  };

  factory ComicChapterFileList.fromJson(Map<String, dynamic> json) {
    final revision = json['sourceRevision'];
    final count = json['pageCount'];
    final rawPages = json['pages'];
    if (revision is! String || revision.isEmpty || count is! int || count < 0 ||
        rawPages is! List || rawPages.length > count) {
      throw const FormatException('invalid comic chapter file list');
    }
    final pages = <ComicPageFile>[];
    final indexes = <int>{};
    final names = <String>{};
    final ids = <String>{};
    for (final raw in rawPages) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('invalid comic page file');
      }
      final page = ComicPageFile.fromJson(raw);
      if (page.logicalIndex >= count || !indexes.add(page.logicalIndex) ||
          !names.add(page.fileName) || !ids.add(page.pageId)) {
        throw const FormatException('ambiguous comic chapter file list');
      }
      pages.add(page);
    }
    pages.sort((a, b) => a.logicalIndex.compareTo(b.logicalIndex));
    return ComicChapterFileList(sourceRevision: revision, pageCount: count,
      pages: List.unmodifiable(pages));
  }
}
