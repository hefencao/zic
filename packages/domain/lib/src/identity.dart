enum PixelFormat { rgba8888, bgra8888 }

enum RendererKind { flutterImage, androidTexture, iosTexture }

enum ResourceKind { download, decode }

final class ContentId {
  const ContentId({
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.pageId,
  });

  final String sourceId;
  final String comicId;
  final String chapterId;
  final String pageId;

  String get key => '$sourceId/$comicId/$chapterId/$pageId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContentId &&
          sourceId == other.sourceId &&
          comicId == other.comicId &&
          chapterId == other.chapterId &&
          pageId == other.pageId;

  @override
  int get hashCode => Object.hash(sourceId, comicId, chapterId, pageId);

  @override
  String toString() => 'ContentId($key)';
}

final class DownloadId {
  const DownloadId({
    required this.content,
    required this.sourceRevision,
    required this.canonicalUri,
  });

  final ContentId content;
  final String sourceRevision;
  final Uri canonicalUri;

  String get key =>
      '${content.key}|$sourceRevision|${canonicalUri.toString()}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadId &&
          content == other.content &&
          sourceRevision == other.sourceRevision &&
          canonicalUri == other.canonicalUri;

  @override
  int get hashCode => Object.hash(content, sourceRevision, canonicalUri);

  @override
  String toString() => 'DownloadId($key)';
}

final class DecodeId {
  DecodeId({
    required this.download,
    required this.physicalWidth,
    required this.physicalHeight,
    required this.pixelFormat,
    required this.renderer,
  })  : assert(physicalWidth > 0),
        assert(physicalHeight > 0);

  final DownloadId download;
  final int physicalWidth;
  final int physicalHeight;
  final PixelFormat pixelFormat;
  final RendererKind renderer;

  String get key =>
      '${download.key}|${physicalWidth}x$physicalHeight|'
      '${pixelFormat.name}|${renderer.name}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecodeId &&
          download == other.download &&
          physicalWidth == other.physicalWidth &&
          physicalHeight == other.physicalHeight &&
          pixelFormat == other.pixelFormat &&
          renderer == other.renderer;

  @override
  int get hashCode => Object.hash(
        download,
        physicalWidth,
        physicalHeight,
        pixelFormat,
        renderer,
      );

  @override
  String toString() => 'DecodeId($key)';
}

final class ResourceId {
  const ResourceId._(this.kind, this.key);

  factory ResourceId.download(DownloadId id) =>
      ResourceId._(ResourceKind.download, id.key);

  factory ResourceId.decode(DecodeId id) =>
      ResourceId._(ResourceKind.decode, id.key);

  final ResourceKind kind;
  final String key;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceId && kind == other.kind && key == other.key;

  @override
  int get hashCode => Object.hash(kind, key);

  @override
  String toString() => 'ResourceId(${kind.name}:$key)';
}

int alignPhysicalDimension(int value, {int alignment = 8}) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'value', 'must be positive');
  }
  if (alignment <= 0) {
    throw ArgumentError.value(alignment, 'alignment', 'must be positive');
  }
  return ((value + alignment - 1) ~/ alignment) * alignment;
}
