import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('runtime requests round-trip through one versioned message schema', () {
    final request = ExternalPluginRuntimeRequest.browse(
      requestId: 'request-7',
      externalSourceId: '1234567890123456789',
      query: 'history',
      offset: 24,
      limit: 24,
    );

    final decoded = ExternalPluginRuntimeRequest.fromMessage(
      request.toMessage(),
    );

    expect(decoded.requestId, 'request-7');
    expect(decoded.operation, ExternalPluginRuntimeOperation.browse);
    expect(decoded.externalSourceId, '1234567890123456789');
    expect(decoded.arguments['query'], 'history');
    expect(decoded.arguments['offset'], 24);
  });

  test('runtime responses preserve typed binary resources', () {
    final response = ExternalPluginRuntimeResponse.success(
      requestId: 'request-8',
      payload: Uint8List.fromList(<int>[1, 2, 3]),
    );

    final decoded = ExternalPluginRuntimeResponse.fromMessage(
      response.toMessage(),
    );

    expect(decoded.payload, isA<Uint8List>());
    expect((decoded.payload! as Uint8List).toList(), <int>[1, 2, 3]);
  });

  test('source handshake round-trips ratings without runtime code', () {
    final descriptor = ExternalPluginRuntimeSourceDescriptor(
      externalId: 'fixture',
      name: 'Fixture',
      language: 'en',
      website: Uri.parse('https://example.invalid'),
      contentRatings: const <SourceContentRating>{
        SourceContentRating.safe,
        SourceContentRating.erotica,
      },
    );

    final decoded = ExternalPluginRuntimeSourceDescriptor.fromMessage(
      descriptor.toMessage(),
    );

    expect(decoded.externalId, 'fixture');
    expect(decoded.contentRatings, contains(SourceContentRating.erotica));
  });

  test('operation schema rejects unknown arguments and relative resources', () {
    expect(
      () => ExternalPluginRuntimeRequest(
        requestId: 'request-1',
        operation: ExternalPluginRuntimeOperation.loadComic,
        externalSourceId: 'fixture',
        arguments: const <String, Object?>{
          'comicId': 'comic',
          'readerMode': 'paged',
        },
      ),
      throwsFormatException,
    );
    expect(
      () => ExternalPluginRuntimeRequest.loadResource(
        requestId: 'request-2',
        externalSourceId: 'fixture',
        uri: Uri.parse('relative/page.jpg'),
      ),
      throwsFormatException,
    );
  });

  test('response schema rejects simultaneous result and error branches', () {
    expect(
      () => ExternalPluginRuntimeResponse.fromMessage(
        <String, Object?>{
          'schemaVersion': 1,
          'requestId': 'request-3',
          'ok': true,
          'payload': <String, Object?>{'value': true},
          'error': <String, Object?>{
            'code': 'bad',
            'message': 'bad',
            'retryable': false,
            'details': <String, Object?>{},
          },
        },
      ),
      throwsFormatException,
    );
  });
}
