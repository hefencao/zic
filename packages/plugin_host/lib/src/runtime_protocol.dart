import 'dart:typed_data';

import 'package:catalog/catalog.dart';

/// Versioned, ecosystem-neutral operation set used across isolated plugin
/// process boundaries.
///
/// The protocol deliberately contains catalog/source concepts only. Reader,
/// navigation, demand, DownloadSession and artifact ownership never cross this
/// boundary.
enum ExternalPluginRuntimeOperation {
  browse,
  loadComic,
  loadComicPreview,
  loadComicComments,
  loadChapter,
  loadResource,
  resolveResource,
  retryResource,
  loadSourceSettings,
  updateSourceSetting,
  loadSourceAccount,
  loginSourceAccount,
  logoutSourceAccount,
}

/// Runtime-discovered source metadata returned after the inspected payload has
/// been activated inside its isolated backend.
final class ExternalPluginRuntimeSourceDescriptor {
  ExternalPluginRuntimeSourceDescriptor({
    required this.externalId,
    required this.name,
    required this.language,
    required this.website,
    this.supportsSearch = true,
    this.supportsComicPreview = false,
    this.supportsComicComments = false,
    this.browserUserAgent,
    Iterable<SourceContentRating> contentRatings = const <SourceContentRating>{
      SourceContentRating.safe,
      SourceContentRating.suggestive,
    },
  }) : contentRatings = Set<SourceContentRating>.unmodifiable(contentRatings) {
    if (externalId.trim().isEmpty ||
        name.trim().isEmpty ||
        language.trim().isEmpty ||
        (browserUserAgent != null && browserUserAgent!.trim().isEmpty) ||
        this.contentRatings.isEmpty) {
      throw ArgumentError('external source descriptor is incomplete');
    }
    if (website.scheme != 'http' && website.scheme != 'https') {
      throw ArgumentError.value(website, 'website', 'must use http or https');
    }
  }

  final String externalId;
  final String name;
  final String language;
  final Uri website;
  final bool supportsSearch;
  final bool supportsComicPreview;
  final bool supportsComicComments;
  final String? browserUserAgent;
  final Set<SourceContentRating> contentRatings;

  Map<String, Object?> toMessage() {
    final ratings = contentRatings.map((value) => value.name).toList()..sort();
    return <String, Object?>{
      'externalId': externalId,
      'name': name,
      'language': language,
      'website': website.toString(),
      'supportsSearch': supportsSearch,
      'supportsComicPreview': supportsComicPreview,
      'supportsComicComments': supportsComicComments,
      if (browserUserAgent != null) 'browserUserAgent': browserUserAgent,
      'contentRatings': ratings,
    };
  }

  factory ExternalPluginRuntimeSourceDescriptor.fromMessage(Object? value) {
    final message = _stringObjectMap(value, 'source descriptor');
    final ratings = _objectList(message['contentRatings'], 'contentRatings')
        .map((value) {
      final name = _requiredStringValue(value, 'content rating');
      try {
        return SourceContentRating.values.byName(name);
      } on ArgumentError {
        throw FormatException('unknown source content rating: $name');
      }
    });
    final website = Uri.tryParse(_requiredString(message, 'website'));
    if (website == null) {
      throw const FormatException('source website is invalid');
    }
    return ExternalPluginRuntimeSourceDescriptor(
      externalId: _requiredString(message, 'externalId'),
      name: _requiredString(message, 'name'),
      language: _requiredString(message, 'language'),
      website: website,
      supportsSearch: _requiredBool(message, 'supportsSearch'),
      supportsComicPreview:
          _optionalBool(message['supportsComicPreview']) ?? false,
      supportsComicComments:
          _optionalBool(message['supportsComicComments']) ?? false,
      browserUserAgent: switch (message['browserUserAgent']) {
        null => null,
        final String value when value.trim().isNotEmpty => value,
        _ => throw const FormatException(
            'source browserUserAgent must be a non-empty string',
          ),
      },
      contentRatings: ratings,
    );
  }
}

/// One operation sent to an isolated Mihon or Venera runtime.
final class ExternalPluginRuntimeRequest {
  ExternalPluginRuntimeRequest({
    required this.requestId,
    required this.operation,
    required this.externalSourceId,
    Map<String, Object?> arguments = const <String, Object?>{},
  }) : arguments = Map<String, Object?>.unmodifiable(arguments) {
    if (requestId.trim().isEmpty || externalSourceId.trim().isEmpty) {
      throw ArgumentError('runtime request identity must not be empty');
    }
    _validateWireValue(this.arguments, label: 'request arguments');
    _validateArguments(operation, this.arguments);
  }

  static const int schemaVersion = 1;

  final String requestId;
  final ExternalPluginRuntimeOperation operation;
  final String externalSourceId;
  final Map<String, Object?> arguments;

  factory ExternalPluginRuntimeRequest.browse({
    required String requestId,
    required String externalSourceId,
    required String query,
    required int offset,
    required int limit,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.browse,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{
          'query': query,
          'offset': offset,
          'limit': limit,
        },
      );

  factory ExternalPluginRuntimeRequest.loadComic({
    required String requestId,
    required String externalSourceId,
    required String comicId,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.loadComic,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{'comicId': comicId},
      );

  factory ExternalPluginRuntimeRequest.loadComicPreview({
    required String requestId,
    required String externalSourceId,
    required String comicId,
    String? nextToken,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.loadComicPreview,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{
          'comicId': comicId,
          'nextToken': nextToken,
        },
      );

  factory ExternalPluginRuntimeRequest.loadComicComments({
    required String requestId,
    required String externalSourceId,
    required String comicId,
    String? subId,
    required int page,
    String? replyTo,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.loadComicComments,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{
          'comicId': comicId,
          'subId': subId,
          'page': page,
          'replyTo': replyTo,
        },
      );

  factory ExternalPluginRuntimeRequest.loadChapter({
    required String requestId,
    required String externalSourceId,
    required String chapterId,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.loadChapter,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{'chapterId': chapterId},
      );

  factory ExternalPluginRuntimeRequest.loadResource({
    required String requestId,
    required String externalSourceId,
    required Uri uri,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.loadResource,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{'uri': uri.toString()},
      );

  factory ExternalPluginRuntimeRequest.resolveResource({
    required String requestId,
    required String externalSourceId,
    required Uri uri,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.resolveResource,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{'uri': uri.toString()},
      );

  factory ExternalPluginRuntimeRequest.retryResource({
    required String requestId,
    required String externalSourceId,
    required Uri uri,
  }) =>
      ExternalPluginRuntimeRequest(
        requestId: requestId,
        operation: ExternalPluginRuntimeOperation.retryResource,
        externalSourceId: externalSourceId,
        arguments: <String, Object?>{'uri': uri.toString()},
      );

  Map<String, Object?> toMessage() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'requestId': requestId,
        'operation': operation.name,
        'externalSourceId': externalSourceId,
        'arguments': arguments,
      };

  factory ExternalPluginRuntimeRequest.fromMessage(Object? value) {
    final message = _stringObjectMap(value, 'runtime request');
    final version = _requiredInt(message, 'schemaVersion');
    if (version != schemaVersion) {
      throw FormatException('unsupported runtime request schema: $version');
    }
    final operationName = _requiredString(message, 'operation');
    late final ExternalPluginRuntimeOperation operation;
    try {
      operation = ExternalPluginRuntimeOperation.values.byName(operationName);
    } on ArgumentError {
      throw FormatException('unknown runtime operation: $operationName');
    }
    return ExternalPluginRuntimeRequest(
      requestId: _requiredString(message, 'requestId'),
      operation: operation,
      externalSourceId: _requiredString(message, 'externalSourceId'),
      arguments: _stringObjectMap(message['arguments'], 'request arguments'),
    );
  }
}

final class ExternalPluginRuntimeError {
  ExternalPluginRuntimeError({
    required this.code,
    required this.message,
    this.retryable = false,
    Map<String, Object?> details = const <String, Object?>{},
  }) : details = Map<String, Object?>.unmodifiable(details) {
    if (code.trim().isEmpty || message.trim().isEmpty) {
      throw ArgumentError('runtime error code and message must not be empty');
    }
    _validateWireValue(this.details, label: 'runtime error details');
  }

  final String code;
  final String message;
  final bool retryable;
  final Map<String, Object?> details;

  Map<String, Object?> toMessage() => <String, Object?>{
        'code': code,
        'message': message,
        'retryable': retryable,
        'details': details,
      };

  factory ExternalPluginRuntimeError.fromMessage(Object? value) {
    final message = _stringObjectMap(value, 'runtime error');
    return ExternalPluginRuntimeError(
      code: _requiredString(message, 'code'),
      message: _requiredString(message, 'message'),
      retryable: _requiredBool(message, 'retryable'),
      details: _stringObjectMap(message['details'], 'runtime error details'),
    );
  }
}

/// Response envelope. Exactly one of [payload] and [error] is present.
final class ExternalPluginRuntimeResponse {
  ExternalPluginRuntimeResponse._({
    required this.requestId,
    required this.payload,
    required this.error,
  }) {
    if (requestId.trim().isEmpty || (payload == null) == (error == null)) {
      throw ArgumentError('runtime response must contain one result branch');
    }
    if (payload != null) {
      _validateWireValue(payload, label: 'runtime response payload');
    }
  }

  static const int schemaVersion = 1;

  final String requestId;
  final Object? payload;
  final ExternalPluginRuntimeError? error;

  bool get isSuccess => error == null;

  factory ExternalPluginRuntimeResponse.success({
    required String requestId,
    required Object payload,
  }) =>
      ExternalPluginRuntimeResponse._(
        requestId: requestId,
        payload: payload,
        error: null,
      );

  factory ExternalPluginRuntimeResponse.failure({
    required String requestId,
    required ExternalPluginRuntimeError error,
  }) =>
      ExternalPluginRuntimeResponse._(
        requestId: requestId,
        payload: null,
        error: error,
      );

  Map<String, Object?> toMessage() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'requestId': requestId,
        'ok': isSuccess,
        if (isSuccess) 'payload': payload,
        if (!isSuccess) 'error': error!.toMessage(),
      };

  factory ExternalPluginRuntimeResponse.fromMessage(Object? value) {
    final message = _stringObjectMap(value, 'runtime response');
    final version = _requiredInt(message, 'schemaVersion');
    if (version != schemaVersion) {
      throw FormatException('unsupported runtime response schema: $version');
    }
    final requestId = _requiredString(message, 'requestId');
    final ok = _requiredBool(message, 'ok');
    if (ok) {
      if (!message.containsKey('payload') || message.containsKey('error')) {
        throw const FormatException('successful runtime response is invalid');
      }
      final payload = message['payload'];
      if (payload == null) {
        throw const FormatException('successful runtime payload is null');
      }
      return ExternalPluginRuntimeResponse.success(
        requestId: requestId,
        payload: payload,
      );
    }
    if (message.containsKey('payload') || !message.containsKey('error')) {
      throw const FormatException('failed runtime response is invalid');
    }
    return ExternalPluginRuntimeResponse.failure(
      requestId: requestId,
      error: ExternalPluginRuntimeError.fromMessage(message['error']),
    );
  }
}

/// One already-isolated runtime process/session.
///
/// Implementations may use Binder, a method channel to a dedicated Android
/// process, or an isolate-backed JavaScript engine. They must preserve request
/// IDs and return only protocol-compatible values.
abstract interface class ExternalPluginRuntimeConnection {
  List<ExternalPluginRuntimeSourceDescriptor> get sources;

  Future<ExternalPluginRuntimeResponse> invoke(
    ExternalPluginRuntimeRequest request,
  );

  Future<void> close();
}

/// Optional connection capability for cooperative cancellation.
abstract interface class CancellableExternalPluginRuntimeConnection
    implements ExternalPluginRuntimeConnection {
  Future<void> cancel(String requestId);
}

void _validateArguments(
  ExternalPluginRuntimeOperation operation,
  Map<String, Object?> arguments,
) {
  switch (operation) {
    case ExternalPluginRuntimeOperation.browse:
      _expectKeys(arguments, const <String>{'query', 'offset', 'limit'});
      if (arguments['query'] is! String ||
          arguments['offset'] is! int ||
          arguments['limit'] is! int ||
          (arguments['offset']! as int) < 0 ||
          (arguments['limit']! as int) <= 0) {
        throw const FormatException('browse arguments are invalid');
      }
      return;
    case ExternalPluginRuntimeOperation.loadComic:
      _expectSingleNonEmptyString(arguments, 'comicId');
      return;
    case ExternalPluginRuntimeOperation.loadComicPreview:
      _expectKeys(arguments, const <String>{'comicId', 'nextToken'});
      _expectNonEmptyString(arguments, 'comicId');
      _expectNullableString(arguments, 'nextToken');
      return;
    case ExternalPluginRuntimeOperation.loadComicComments:
      _expectKeys(
        arguments,
        const <String>{'comicId', 'subId', 'page', 'replyTo'},
      );
      _expectNonEmptyString(arguments, 'comicId');
      _expectNullableString(arguments, 'subId');
      _expectNullableString(arguments, 'replyTo');
      final page = arguments['page'];
      if (page is! int || page < 1) {
        throw const FormatException('comic comment page is invalid');
      }
      return;
    case ExternalPluginRuntimeOperation.loadChapter:
      _expectSingleNonEmptyString(arguments, 'chapterId');
      return;
    case ExternalPluginRuntimeOperation.loadResource:
    case ExternalPluginRuntimeOperation.resolveResource:
    case ExternalPluginRuntimeOperation.retryResource:
      _expectSingleNonEmptyString(arguments, 'uri');
      final uri = Uri.tryParse(arguments['uri']! as String);
      if (uri == null || !uri.hasScheme) {
        throw const FormatException('resource URI is invalid');
      }
      return;
    case ExternalPluginRuntimeOperation.loadSourceSettings:
      _expectKeys(arguments, const <String>{});
      return;
    case ExternalPluginRuntimeOperation.updateSourceSetting:
      _expectKeys(arguments, const <String>{'key', 'value'});
      final key = arguments['key'];
      final value = arguments['value'];
      if (key is! String ||
          key.trim().isEmpty ||
          (value is! String &&
              value is! bool &&
              value is! int &&
              value is! List<Object?>)) {
        throw const FormatException('source setting arguments are invalid');
      }
      return;
    case ExternalPluginRuntimeOperation.loadSourceAccount:
    case ExternalPluginRuntimeOperation.logoutSourceAccount:
      _expectKeys(arguments, const <String>{});
      return;
    case ExternalPluginRuntimeOperation.loginSourceAccount:
      _expectKeys(arguments, const <String>{'mode', 'values'});
      final mode = arguments['mode'];
      final values = arguments['values'];
      if (mode is! String ||
          !const <String>{'credentials', 'cookies', 'web'}.contains(mode) ||
          values is! Map<Object?, Object?> ||
          values.keys.any((key) => key is! String)) {
        throw const FormatException('source login arguments are invalid');
      }
      return;
  }
}

void _expectKeys(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    throw const FormatException(
      'runtime request arguments do not match operation',
    );
  }
}

void _expectSingleNonEmptyString(Map<String, Object?> value, String key) {
  _expectKeys(value, <String>{key});
  _expectNonEmptyString(value, key);
}

void _expectNonEmptyString(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String || field.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
}

void _expectNullableString(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field != null && field is! String) {
    throw FormatException('$key must be a string or null');
  }
}

void _validateWireValue(
  Object? value, {
  required String label,
  int depth = 0,
}) {
  if (depth > 32) {
    throw FormatException('$label exceeds maximum nesting depth');
  }
  if (value == null ||
      value is bool ||
      value is int ||
      value is double ||
      value is String ||
      value is Uint8List) {
    return;
  }
  if (value is List<Object?>) {
    for (final item in value) {
      _validateWireValue(item, label: label, depth: depth + 1);
    }
    return;
  }
  if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$label contains a non-string map key');
      }
      _validateWireValue(entry.value, label: label, depth: depth + 1);
    }
    return;
  }
  throw FormatException('$label contains unsupported value ${value.runtimeType}');
}

Map<String, Object?> _stringObjectMap(Object? value, String label) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    throw FormatException('$label must be a string-keyed object');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _objectList(Object? value, String label) {
  if (value is! List<Object?>) {
    throw FormatException('$label must be a list');
  }
  return value;
}

String _requiredString(Map<String, Object?> value, String key) =>
    _requiredStringValue(value[key], key);

String _requiredStringValue(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$label must be a non-empty string');
  }
  return value;
}

int _requiredInt(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! int) {
    throw FormatException('$key must be an integer');
  }
  return field;
}

bool _requiredBool(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! bool) {
    throw FormatException('$key must be a boolean');
  }
  return field;
}

bool? _optionalBool(Object? value) {
  if (value == null) return null;
  if (value is! bool) {
    throw const FormatException('optional boolean must be a boolean');
  }
  return value;
}
