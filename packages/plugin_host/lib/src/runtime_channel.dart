import 'dart:async';

import 'runtime_protocol.dart';

/// Raw request/response channel owned by one isolated plugin runtime.
///
/// Android implementations may use Binder or a method channel connected to a
/// dedicated process. Venera implementations may use an isolate or native JS
/// engine port. The channel never receives zic domain, Reader, download or
/// artifact objects; every value must be a protocol-compatible message.
abstract interface class ExternalPluginRuntimeMessageChannel {
  Future<Object?> send(Object? requestMessage);

  Future<void> close();
}

/// Optional channel capability for cooperative cancellation of one request.
///
/// Cancellation is best-effort: the host still retains its concurrency permit
/// until the original [send] Future exits.
abstract interface class CancellableExternalPluginRuntimeMessageChannel
    implements ExternalPluginRuntimeMessageChannel {
  Future<void> cancel(String requestId);
}

/// Versioned startup message produced by an isolated runtime after payload
/// validation and source discovery, before any catalog operation is accepted.
final class ExternalPluginRuntimeHandshake {
  ExternalPluginRuntimeHandshake({
    required this.runtimeId,
    required Iterable<ExternalPluginRuntimeSourceDescriptor> sources,
  }) : sources = List<ExternalPluginRuntimeSourceDescriptor>.unmodifiable(
          sources,
        ) {
    if (runtimeId.trim().isEmpty || this.sources.isEmpty) {
      throw ArgumentError('runtime handshake is incomplete');
    }
    final sourceIds = <String>{};
    for (final source in this.sources) {
      if (!sourceIds.add(source.externalId)) {
        throw ArgumentError.value(
          source.externalId,
          'sources',
          'runtime handshake contains a duplicate source identity',
        );
      }
    }
  }

  static const int schemaVersion = 1;

  final String runtimeId;
  final List<ExternalPluginRuntimeSourceDescriptor> sources;

  Map<String, Object?> toMessage() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'runtimeId': runtimeId,
        'sources': sources.map((source) => source.toMessage()).toList(),
      };

  factory ExternalPluginRuntimeHandshake.fromMessage(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value.keys.any((key) => key is! String)) {
      throw const FormatException('runtime handshake must be an object');
    }
    final message = Map<String, Object?>.from(value);
    final version = message['schemaVersion'];
    if (version is! int || version != schemaVersion) {
      throw FormatException('unsupported runtime handshake schema: $version');
    }
    final runtimeId = message['runtimeId'];
    final rawSources = message['sources'];
    if (runtimeId is! String || runtimeId.trim().isEmpty) {
      throw const FormatException('runtime handshake id is invalid');
    }
    if (rawSources is! List<Object?> || rawSources.isEmpty) {
      throw const FormatException('runtime handshake sources are invalid');
    }
    return ExternalPluginRuntimeHandshake(
      runtimeId: runtimeId,
      sources: rawSources.map(
        ExternalPluginRuntimeSourceDescriptor.fromMessage,
      ),
    );
  }
}

/// Converts a raw isolated message channel into the connection contract used by
/// the shared source adapter.
///
/// Serialization is performed on every call, so an Android/Venera backend
/// cannot accidentally return in-process protocol objects that hide an invalid
/// wire representation. Close is joinable and new calls are rejected once
/// teardown begins.
final class MessageChannelExternalPluginRuntimeConnection
    implements CancellableExternalPluginRuntimeConnection {
  MessageChannelExternalPluginRuntimeConnection({
    required ExternalPluginRuntimeHandshake handshake,
    required ExternalPluginRuntimeMessageChannel channel,
  })  : runtimeId = handshake.runtimeId,
        sources = handshake.sources,
        _channel = channel;

  factory MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage({
    required Object? handshakeMessage,
    required ExternalPluginRuntimeMessageChannel channel,
  }) =>
      MessageChannelExternalPluginRuntimeConnection(
        handshake: ExternalPluginRuntimeHandshake.fromMessage(handshakeMessage),
        channel: channel,
      );

  final String runtimeId;

  @override
  final List<ExternalPluginRuntimeSourceDescriptor> sources;

  final ExternalPluginRuntimeMessageChannel _channel;
  bool _closing = false;
  Future<void>? _closeFuture;

  @override
  Future<ExternalPluginRuntimeResponse> invoke(
    ExternalPluginRuntimeRequest request,
  ) async {
    if (_closing) {
      throw StateError('external plugin runtime connection is closing');
    }
    final raw = await _channel.send(request.toMessage());
    final response = ExternalPluginRuntimeResponse.fromMessage(raw);
    if (response.requestId != request.requestId) {
      throw FormatException(
        'runtime response requestId ${response.requestId} does not match '
        '${request.requestId}',
      );
    }
    return response;
  }

  @override
  Future<void> cancel(String requestId) {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(requestId, 'requestId');
    }
    final channel = _channel;
    if (channel is CancellableExternalPluginRuntimeMessageChannel) {
      return channel.cancel(requestId);
    }
    return Future<void>.value();
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closing = true;
    final closing = Future<void>.sync(_channel.close);
    _closeFuture = closing;
    return closing;
  }
}
