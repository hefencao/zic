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

  /// Collision-free framed identity used for new in-memory and persisted
  /// keys. Field contents are length-prefixed, so delimiters in source or
  /// provider identifiers cannot merge two distinct ContentIds.
  String get key =>
      'content:v2${_frame(sourceId)}${_frame(comicId)}'
      '${_frame(chapterId)}${_frame(pageId)}';

  /// The pre-v2 key used by cache metadata and older SQLite rows. Readers of
  /// durable state may accept it only as a compatibility lookup key.
  String get legacyKey => '$sourceId/$comicId/$chapterId/$pageId';

  Map<String, Object> toJson() => <String, Object>{
        'sourceId': sourceId,
        'comicId': comicId,
        'chapterId': chapterId,
        'pageId': pageId,
      };

  factory ContentId.fromJson(Map<String, Object?> json) => ContentId(
        sourceId: json['sourceId']! as String,
        comicId: json['comicId']! as String,
        chapterId: json['chapterId']! as String,
        pageId: json['pageId']! as String,
      );

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
  DownloadId({
    required this.content,
    required this.sourceRevision,
    required this.canonicalUri,
    this.pageIndexHint,
  }) : assert(pageIndexHint == null || pageIndexHint >= 0);

  final ContentId content;
  final String sourceRevision;
  final Uri canonicalUri;

  /// Optional execution-only page position supplied by a manifest-aware
  /// caller. This is deliberately excluded from [key], JSON persistence,
  /// equality and hashing: page order is not logical identity. Version-page
  /// reuse may consume it only after validating the hinted manifest slot's
  /// exact pageId + URI against this DownloadId.
  final int? pageIndexHint;

  // DownloadId is immutable but sits on every Reader planning hot path. Keep
  // its framed/storage keys and structural hash as per-instance derived facts
  // instead of rebuilding the same long provider identity every time a plan
  // touches a Map/Set or lane key. These caches do not change identity or
  // ownership semantics; they only memoize pure projections of final fields.
  late final String _canonicalUriString = canonicalUri.toString();
  late final String _key =
      'download:v2${_frame(content.sourceId)}${_frame(content.comicId)}'
      '${_frame(content.chapterId)}${_frame(content.pageId)}'
      '${_frame(sourceRevision)}${_frame(_canonicalUriString)}';
  late final String _legacyKey =
      '${content.legacyKey}|$sourceRevision|$_canonicalUriString';
  late final int _hashCode = Object.hash(content, sourceRevision, canonicalUri);

  /// Collision-free framed identity used for new keys.
  String get key => _key;

  /// The pre-v2 key used by older cache/index records.
  String get legacyKey => _legacyKey;

  Map<String, Object> toJson() => <String, Object>{
        'content': content.toJson(),
        'sourceRevision': sourceRevision,
        'canonicalUri': canonicalUri.toString(),
      };

  factory DownloadId.fromJson(Map<String, Object?> json) {
    final content = json['content'];
    if (content is! Map) {
      throw const FormatException('content must be an object');
    }
    return DownloadId(
      content: ContentId.fromJson(Map<String, Object?>.from(content)),
      sourceRevision: json['sourceRevision']! as String,
      canonicalUri: Uri.parse(json['canonicalUri']! as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadId &&
          content == other.content &&
          sourceRevision == other.sourceRevision &&
          canonicalUri == other.canonicalUri;

  @override
  int get hashCode => _hashCode;

  @override
  String toString() => 'DownloadId($key)';
}

enum PhysicalMediaIdKind { exact, canonical }

/// Version/provider-independent identity for one mutable encoded-body owner.
///
/// [DownloadId] remains the exact logical/provider identity. A physical media
/// id only answers "which encoded body / single writer is this?" and therefore
/// deliberately carries no request URI, source revision or provider policy.
///
/// [exact] is the compatibility fallback for media that has no stronger
/// canonical projection yet. Its payload is the framed [DownloadId.key], so a
/// storage layout can preserve the historical exact staging token without
/// treating that exact id as the physical type. [canonical] accepts an opaque
/// composition-owned stable key such as a version-family media coordinate.
final class PhysicalMediaId {
  const PhysicalMediaId._({required this.kind, required this.value})
      : assert(value != '');

  factory PhysicalMediaId.exact(DownloadId id) => PhysicalMediaId._(
        kind: PhysicalMediaIdKind.exact,
        value: id.key,
      );

  factory PhysicalMediaId.canonical(String stableKey) {
    if (stableKey.isEmpty) {
      throw ArgumentError.value(stableKey, 'stableKey', 'must not be empty');
    }
    return PhysicalMediaId._(
      kind: PhysicalMediaIdKind.canonical,
      value: stableKey,
    );
  }

  final PhysicalMediaIdKind kind;
  final String value;

  bool get isExactFallback => kind == PhysicalMediaIdKind.exact;

  /// Collision-free physical identity used by registries and durable records.
  String get key =>
      'physical-media:v1${_frame(kind.name)}${_frame(value)}';

  Map<String, Object> toJson() => <String, Object>{
        'kind': kind.name,
        'value': value,
      };

  factory PhysicalMediaId.fromJson(Map<String, Object?> json) {
    final rawKind = json['kind'];
    final rawValue = json['value'];
    if (rawKind is! String || rawValue is! String || rawValue.isEmpty) {
      throw const FormatException('invalid physical media identity');
    }
    final kind = PhysicalMediaIdKind.values.byName(rawKind);
    return PhysicalMediaId._(kind: kind, value: rawValue);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhysicalMediaId && kind == other.kind && value == other.value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'PhysicalMediaId($key)';
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

  // DecodeId is likewise immutable and is repeatedly projected into lane and
  // plan keys while a continuous Reader crosses page boundaries. Memoizing
  // these pure derived values removes repeated DownloadId framing without
  // changing DecodeId equality, scheduling rank or renderer ownership.
  late final String _key =
      'decode:v2${_frame(download.key)}${_frame(physicalWidth.toString())}'
      '${_frame(physicalHeight.toString())}${_frame(pixelFormat.name)}'
      '${_frame(renderer.name)}';
  late final String _legacyKey =
      '${download.legacyKey}|${physicalWidth}x$physicalHeight|'
      '${pixelFormat.name}|${renderer.name}';
  late final int _hashCode = Object.hash(
        download,
        physicalWidth,
        physicalHeight,
        pixelFormat,
        renderer,
      );

  String get key => _key;

  String get legacyKey => _legacyKey;

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
  int get hashCode => _hashCode;

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

String _frame(String value) => '${value.length}:$value';

int alignPhysicalDimension(int value, {int alignment = 8}) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'value', 'must be positive');
  }
  if (alignment <= 0) {
    throw ArgumentError.value(alignment, 'alignment', 'must be positive');
  }
  return ((value + alignment - 1) ~/ alignment) * alignment;
}
