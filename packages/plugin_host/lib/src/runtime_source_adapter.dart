import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';

import 'runtime_limits.dart';
import 'runtime_protocol.dart';

/// Adapts one isolated-runtime connection to ordinary zic catalog sources.
///
/// This is the only layer that understands both the serialized runtime schema
/// and zic domain models. Runtime engines never receive Reader/session APIs.
final class ExternalPluginRuntimeSession
    implements ExternalComicPluginSession {
  ExternalPluginRuntimeSession({
    required this.plugin,
    required ExternalPluginRuntimeConnection connection,
    required ExternalPluginRuntimeLimits limits,
  })  : _connection = connection,
        _limits = limits,
        _gate = _RuntimeInvocationGate(limits) {
    limits.validate();
    final descriptors = connection.sources;
    if (descriptors.isEmpty) {
      throw StateError('external runtime exposed no sources');
    }
    final externalIds = <String>{};
    for (final descriptor in descriptors) {
      if (!externalIds.add(descriptor.externalId)) {
        throw StateError(
          'external runtime exposed duplicate source ${descriptor.externalId}',
        );
      }
    }
    _sources = List<BrowsableComicSource>.unmodifiable(
      descriptors.map(
        (descriptor) => _RuntimeBrowsableComicSource(
          format: plugin.format,
          descriptor: descriptor,
          invoke: _invoke,
        ),
      ),
    );
  }

  @override
  final ExternalComicPluginCatalogEntry plugin;

  final ExternalPluginRuntimeConnection _connection;
  final ExternalPluginRuntimeLimits _limits;
  final _RuntimeInvocationGate _gate;
  late final List<BrowsableComicSource> _sources;
  int _nextRequestId = 1;
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  List<BrowsableComicSource> get sources => _sources;

  Future<Object> _invoke(
    ExternalPluginRuntimeOperation operation,
    String externalSourceId,
    Map<String, Object?> arguments,
  ) async {
    if (_closed) {
      throw StateError('external plugin runtime session is closed');
    }
    final request = ExternalPluginRuntimeRequest(
      requestId: 'request-${_nextRequestId++}',
      operation: operation,
      externalSourceId: externalSourceId,
      arguments: arguments,
    );
    late final ExternalPluginRuntimeResponse response;
    try {
      response = await _gate.run(() => _connection.invoke(request));
    } on TimeoutException catch (error) {
      throw Failure(
        code: ErrorCode.source,
        message: 'external plugin invocation timed out',
        cause: error,
      );
    }
    if (response.requestId != request.requestId) {
      throw Failure(
        code: ErrorCode.source,
        message: 'external plugin response request identity mismatch',
      );
    }
    final runtimeError = response.error;
    if (runtimeError != null) {
      throw Failure(
        code: ErrorCode.source,
        message: '${runtimeError.code}: ${runtimeError.message}',
        cause: runtimeError,
      );
    }
    final payload = response.payload;
    if (payload == null) {
      throw const Failure(
        code: ErrorCode.source,
        message: 'external plugin response payload is missing',
      );
    }
    final size = _wireSize(payload);
    if (size > _limits.maxResponseBytes) {
      throw Failure(
        code: ErrorCode.source,
        message: 'external plugin response exceeds limit: '
            '$size > ${_limits.maxResponseBytes}',
      );
    }
    return payload;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final drained = _gate.beginClose();
    Object? closeError;
    StackTrace? closeStackTrace;
    try {
      await _connection.close();
    } on Object catch (error, stackTrace) {
      closeError = error;
      closeStackTrace = stackTrace;
    }
    await drained;
    if (closeError != null) {
      Error.throwWithStackTrace(closeError, closeStackTrace!);
    }
  }
}

typedef _RuntimeInvoke = Future<Object> Function(
  ExternalPluginRuntimeOperation operation,
  String externalSourceId,
  Map<String, Object?> arguments,
);

final class _RuntimeBrowsableComicSource implements BrowsableComicSource {
  _RuntimeBrowsableComicSource({
    required ExternalComicPluginFormat format,
    required ExternalPluginRuntimeSourceDescriptor descriptor,
    required _RuntimeInvoke invoke,
  })  : _externalId = descriptor.externalId,
        _invoke = invoke,
        sourceId = '${_sourcePrefix(format)}${descriptor.externalId}',
        descriptor = ComicSourceDescriptor(
          sourceId: '${_sourcePrefix(format)}${descriptor.externalId}',
          name: descriptor.name,
          language: descriptor.language,
          website: descriptor.website,
          supportsSearch: descriptor.supportsSearch,
          contentRatings: descriptor.contentRatings,
        );

  final String _externalId;
  final _RuntimeInvoke _invoke;

  @override
  final String sourceId;

  @override
  final ComicSourceDescriptor descriptor;

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async {
    if (offset < 0 || limit <= 0) {
      throw ArgumentError('browse offset/limit are invalid');
    }
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.browse,
      _externalId,
      <String, Object?>{
        'query': query,
        'offset': offset,
        'limit': limit,
      },
    );
    final message = _map(payload, 'browse result');
    final items = _list(message['items'], 'browse items').map((value) {
      final item = _map(value, 'browse item');
      return SourceComicSummary(
        sourceId: sourceId,
        comicId: _string(item, 'comicId'),
        title: _string(item, 'title'),
        authors: _stringList(item['authors'], 'authors'),
        coverUri: _optionalUri(item['coverUri'], 'coverUri'),
        description: _optionalString(item['description'], 'description'),
        contentRating: _contentRating(item['contentRating']),
      );
    }).toList(growable: false);
    final resultOffset = _nonNegativeInt(message, 'offset');
    if (resultOffset != offset) {
      throw const FormatException('runtime browse offset mismatch');
    }
    return SourceBrowsePage(
      items: items,
      offset: resultOffset,
      hasMore: _bool(message, 'hasMore'),
    );
  }

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    if (comicId.trim().isEmpty) {
      throw ArgumentError.value(comicId, 'comicId');
    }
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadComic,
      _externalId,
      <String, Object?>{'comicId': comicId},
    );
    final message = _map(payload, 'comic result');
    final comicValue = _map(message['comic'], 'comic');
    final resultComicId = _string(comicValue, 'comicId');
    if (resultComicId != comicId) {
      throw const FormatException('runtime comic identity mismatch');
    }
    final comic = Comic(
      comicId: resultComicId,
      sourceId: sourceId,
      title: _string(comicValue, 'title'),
      authors: _stringList(comicValue['authors'], 'authors'),
      readingDirection: _readingDirection(comicValue['readingDirection']),
      coverUri: _optionalUri(comicValue['coverUri'], 'coverUri'),
      description: _optionalString(comicValue['description'], 'description'),
      createdAt: _optionalDateTime(comicValue['createdAt'], 'createdAt'),
      updatedAt: _optionalDateTime(comicValue['updatedAt'], 'updatedAt'),
    );
    final chapters = _list(message['chapters'], 'chapters')
        .map((value) => _chapter(_map(value, 'chapter'), comicId))
        .toList(growable: false);
    final chapterIds = chapters.map((chapter) => chapter.chapterId).toSet();
    if (chapterIds.length != chapters.length) {
      throw const FormatException('runtime comic contains duplicate chapters');
    }
    return ComicManifest(comic: comic, chapters: chapters);
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    if (chapterId.trim().isEmpty) {
      throw ArgumentError.value(chapterId, 'chapterId');
    }
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadChapter,
      _externalId,
      <String, Object?>{'chapterId': chapterId},
    );
    final message = _map(payload, 'chapter result');
    final comicId = _string(message, 'comicId');
    final chapter = _chapter(_map(message['chapter'], 'chapter'), comicId);
    if (chapter.chapterId != chapterId) {
      throw const FormatException('runtime chapter identity mismatch');
    }
    final pages = _list(message['pages'], 'pages').map((value) {
      final page = _map(value, 'page');
      final resultChapterId = _string(page, 'chapterId');
      if (resultChapterId != chapterId) {
        throw const FormatException('runtime page chapter identity mismatch');
      }
      return PageAsset(
        pageId: _string(page, 'pageId'),
        chapterId: resultChapterId,
        index: _nonNegativeInt(page, 'index'),
        uri: _uri(page['uri'], 'uri'),
        width: _optionalPositiveInt(page['width'], 'width'),
        height: _optionalPositiveInt(page['height'], 'height'),
        byteLength: _optionalNonNegativeInt(page['byteLength'], 'byteLength'),
        contentKindHint: _contentKind(page['contentKindHint']),
        animatedHint: _optionalBool(page['animatedHint']) ?? false,
        checksum: _optionalString(page['checksum'], 'checksum'),
      );
    }).toList(growable: false);
    return ChapterManifest(
      sourceId: sourceId,
      comicId: comicId,
      chapter: chapter,
      pages: pages,
      readingDirection: _readingDirection(message['readingDirection']),
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    if (!uri.hasScheme) {
      throw ArgumentError.value(uri, 'uri', 'must be absolute');
    }
    final payload = await _invoke(
      ExternalPluginRuntimeOperation.loadResource,
      _externalId,
      <String, Object?>{'uri': uri.toString()},
    );
    if (payload is! Uint8List) {
      throw const FormatException(
        'runtime resource result must be a binary payload',
      );
    }
    return payload;
  }
}

final class _RuntimeInvocationGate {
  _RuntimeInvocationGate(this.limits);

  final ExternalPluginRuntimeLimits limits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  Completer<void>? _drained;
  int _active = 0;
  bool _closing = false;

  Future<T> run<T>(Future<T> Function() action) async {
    if (_closing) {
      throw StateError('external plugin runtime is closing');
    }
    if (_active >= limits.maxConcurrentInvocations) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
      if (_closing) {
        // The released invocation transferred its permit to this waiter.
        // Return it before rejecting work that lost the close race.
        _release();
        throw StateError('external plugin runtime is closing');
      }
    } else {
      _active++;
    }
    late final Future<T> operation;
    try {
      operation = action();
    } on Object {
      _release();
      rethrow;
    }
    operation.then<void>(
      (_) => _release(),
      onError: (Object _, StackTrace __) => _release(),
    );
    return operation.timeout(limits.invocationTimeout);
  }

  Future<void> beginClose() {
    if (_closing) {
      return _drained?.future ?? Future<void>.value();
    }
    _closing = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(
            StateError('external plugin runtime is closing'),
          );
    }
    if (_active == 0) {
      return Future<void>.value();
    }
    _drained = Completer<void>();
    return _drained!.future;
  }

  void _release() {
    if (!_closing && _waiters.isNotEmpty) {
      // Transfer the active permit directly to the oldest waiter. Keeping
      // [_active] unchanged prevents a newly arriving call from stealing the
      // slot before the waiter resumes.
      _waiters.removeFirst().complete();
      return;
    }
    _active--;
    if (_active < 0) {
      throw StateError('external plugin invocation permit underflow');
    }
    if (_closing && _active == 0) {
      _drained?.complete();
      _drained = null;
    }
  }
}

String _sourcePrefix(ExternalComicPluginFormat format) => switch (format) {
      ExternalComicPluginFormat.mihonExtension => 'mihon:',
      ExternalComicPluginFormat.veneraJavaScript => 'venera:',
    };

int _wireSize(Object? value, [int depth = 0]) {
  if (depth > 32) {
    throw const FormatException('runtime response is nested too deeply');
  }
  if (value == null) {
    return 0;
  }
  if (value is Uint8List) {
    return value.lengthInBytes;
  }
  if (value is String) {
    return utf8.encode(value).length;
  }
  if (value is bool || value is int || value is double) {
    return 8;
  }
  if (value is List<Object?>) {
    return value.fold<int>(
      0,
      (sum, item) => sum + _wireSize(item, depth + 1),
    );
  }
  if (value is Map<Object?, Object?>) {
    var size = 0;
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('runtime response map key is not a string');
      }
      size += utf8.encode(entry.key as String).length;
      size += _wireSize(entry.value, depth + 1);
    }
    return size;
  }
  throw FormatException(
    'runtime response contains unsupported ${value.runtimeType}',
  );
}

Chapter _chapter(Map<String, Object?> value, String comicId) {
  final resultComicId = _string(value, 'comicId');
  if (resultComicId != comicId) {
    throw const FormatException('runtime chapter comic identity mismatch');
  }
  return Chapter(
    chapterId: _string(value, 'chapterId'),
    comicId: resultComicId,
    title: _string(value, 'title'),
    sequence: _nonNegativeInt(value, 'sequence'),
    pageCount: _nonNegativeInt(value, 'pageCount'),
    sourceRevision: _string(value, 'sourceRevision'),
    publishedAt: _optionalDateTime(value['publishedAt'], 'publishedAt'),
  );
}

Map<String, Object?> _map(Object? value, String label) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    throw FormatException('$label must be an object');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, String label) {
  if (value is! List<Object?>) {
    throw FormatException('$label must be a list');
  }
  return value;
}

String _string(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String || field.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return field;
}

String? _optionalString(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$label must be a string');
  }
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

List<String> _stringList(Object? value, String label) {
  final list = _list(value, label);
  if (list.any((item) => item is! String)) {
    throw FormatException('$label must contain strings');
  }
  return List<String>.unmodifiable(list.cast<String>());
}

bool _bool(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! bool) {
    throw FormatException('$key must be a boolean');
  }
  return field;
}

bool? _optionalBool(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! bool) {
    throw const FormatException('optional boolean has invalid type');
  }
  return value;
}

int _nonNegativeInt(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! int || field < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return field;
}

int? _optionalPositiveInt(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! int || value <= 0) {
    throw FormatException('$label must be a positive integer');
  }
  return value;
}

int? _optionalNonNegativeInt(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! int || value < 0) {
    throw FormatException('$label must be a non-negative integer');
  }
  return value;
}

Uri _uri(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$label must be a URI string');
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) {
    throw FormatException('$label must be an absolute URI');
  }
  return uri;
}

Uri? _optionalUri(Object? value, String label) {
  if (value == null) {
    return null;
  }
  return _uri(value, label);
}

DateTime? _optionalDateTime(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$label must be an ISO-8601 string');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$label is not a valid date-time');
  }
  return parsed;
}

ReadingDirection _readingDirection(Object? value) {
  if (value is! String) {
    throw const FormatException('readingDirection must be a string');
  }
  try {
    return ReadingDirection.values.byName(value);
  } on ArgumentError {
    throw FormatException('unknown reading direction: $value');
  }
}

ContentKindHint _contentKind(Object? value) {
  if (value == null) {
    return ContentKindHint.unknown;
  }
  if (value is! String) {
    throw const FormatException('contentKindHint must be a string');
  }
  try {
    return ContentKindHint.values.byName(value);
  } on ArgumentError {
    throw FormatException('unknown content kind: $value');
  }
}

SourceContentRating _contentRating(Object? value) {
  if (value == null) {
    return SourceContentRating.safe;
  }
  if (value is! String) {
    throw const FormatException('contentRating must be a string');
  }
  try {
    return SourceContentRating.values.byName(value);
  } on ArgumentError {
    throw FormatException('unknown content rating: $value');
  }
}
