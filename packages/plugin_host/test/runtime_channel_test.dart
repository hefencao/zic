import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  final descriptor = ExternalPluginRuntimeSourceDescriptor(
    externalId: 'source-1',
    name: 'Fixture',
    language: 'en',
    website: Uri.parse('https://example.invalid'),
    contentRatings: const <SourceContentRating>{SourceContentRating.safe},
  );

  test('handshake and binary response cross the raw message boundary',
      () async {
    final channel = _RecordingMessageChannel((message) {
      final request = ExternalPluginRuntimeRequest.fromMessage(message);
      expect(request.operation, ExternalPluginRuntimeOperation.loadResource);
      return ExternalPluginRuntimeResponse.success(
        requestId: request.requestId,
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      ).toMessage();
    });
    final connection =
        MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
      handshakeMessage: ExternalPluginRuntimeHandshake(
        runtimeId: 'runtime-1',
        sources: <ExternalPluginRuntimeSourceDescriptor>[descriptor],
      ).toMessage(),
      channel: channel,
    );

    final response = await connection.invoke(
      ExternalPluginRuntimeRequest.loadResource(
        requestId: 'request-1',
        externalSourceId: 'source-1',
        uri: Uri.parse('https://example.invalid/page.webp'),
      ),
    );

    expect(connection.runtimeId, 'runtime-1');
    expect(connection.sources.single.externalId, 'source-1');
    expect(response.payload, isA<Uint8List>());
    expect(response.payload, <int>[1, 2, 3]);
    expect(channel.messages, hasLength(1));
  });

  test('malformed raw responses are rejected at the channel boundary',
      () async {
    final channel = _RecordingMessageChannel(
      (_) => <String, Object?>{
        'schemaVersion': 1,
        'requestId': 'request-1',
        'ok': true,
      },
    );
    final connection = MessageChannelExternalPluginRuntimeConnection(
      handshake: ExternalPluginRuntimeHandshake(
        runtimeId: 'runtime-1',
        sources: <ExternalPluginRuntimeSourceDescriptor>[descriptor],
      ),
      channel: channel,
    );

    await expectLater(
      connection.invoke(
        ExternalPluginRuntimeRequest.loadComic(
          requestId: 'request-1',
          externalSourceId: 'source-1',
          comicId: 'comic-1',
        ),
      ),
      throwsFormatException,
    );
  });

  test('response request identity must match the invocation', () async {
    final channel = _RecordingMessageChannel(
      (_) => ExternalPluginRuntimeResponse.success(
        requestId: 'other-request',
        payload: const <String, Object?>{},
      ).toMessage(),
    );
    final connection = MessageChannelExternalPluginRuntimeConnection(
      handshake: ExternalPluginRuntimeHandshake(
        runtimeId: 'runtime-1',
        sources: <ExternalPluginRuntimeSourceDescriptor>[descriptor],
      ),
      channel: channel,
    );

    await expectLater(
      connection.invoke(
        ExternalPluginRuntimeRequest.loadComic(
          requestId: 'request-1',
          externalSourceId: 'source-1',
          comicId: 'comic-1',
        ),
      ),
      throwsFormatException,
    );
  });

  test('close is joinable and rejects new messages immediately', () async {
    final closeGate = Completer<void>();
    final channel = _RecordingMessageChannel(
      (_) => throw StateError('unexpected invocation'),
      closeFuture: closeGate.future,
    );
    final connection = MessageChannelExternalPluginRuntimeConnection(
      handshake: ExternalPluginRuntimeHandshake(
        runtimeId: 'runtime-1',
        sources: <ExternalPluginRuntimeSourceDescriptor>[descriptor],
      ),
      channel: channel,
    );

    final first = connection.close();
    final second = connection.close();
    expect(identical(first, second), isTrue);
    await expectLater(
      connection.invoke(
        ExternalPluginRuntimeRequest.loadComic(
          requestId: 'request-1',
          externalSourceId: 'source-1',
          comicId: 'comic-1',
        ),
      ),
      throwsStateError,
    );
    expect(channel.closeCalls, 1);

    closeGate.complete();
    await first;
  });

  test('handshake schema and source payload are validated', () {
    expect(
      () => ExternalPluginRuntimeHandshake.fromMessage(
        <String, Object?>{
          'schemaVersion': 2,
          'runtimeId': 'runtime-1',
          'sources': <Object?>[descriptor.toMessage()],
        },
      ),
      throwsFormatException,
    );
    expect(
      () => ExternalPluginRuntimeHandshake.fromMessage(
        <String, Object?>{
          'schemaVersion': 1,
          'runtimeId': 'runtime-1',
          'sources': <Object?>[],
        },
      ),
      throwsFormatException,
    );
    expect(
      () => ExternalPluginRuntimeHandshake(
        runtimeId: 'runtime-1',
        sources: <ExternalPluginRuntimeSourceDescriptor>[
          descriptor,
          descriptor,
        ],
      ),
      throwsArgumentError,
    );
  });
}

final class _RecordingMessageChannel
    implements ExternalPluginRuntimeMessageChannel {
  _RecordingMessageChannel(this.handler, {Future<void>? closeFuture})
      : _closeFuture = closeFuture ?? Future<void>.value();

  final Object? Function(Object? message) handler;
  final Future<void> _closeFuture;
  final List<Object?> messages = <Object?>[];
  int closeCalls = 0;

  @override
  Future<Object?> send(Object? requestMessage) async {
    messages.add(requestMessage);
    return handler(requestMessage);
  }

  @override
  Future<void> close() {
    closeCalls++;
    return _closeFuture;
  }
}
