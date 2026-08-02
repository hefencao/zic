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

  test('resource request and retry operations share the absolute URI schema',
      () {
    final uri = Uri.parse('venera-resource:durable-page');
    final resolved = ExternalPluginRuntimeRequest.fromMessage(
      ExternalPluginRuntimeRequest.resolveResource(
        requestId: 'resolve-1',
        externalSourceId: 'fixture',
        uri: uri,
      ).toMessage(),
    );
    final retried = ExternalPluginRuntimeRequest.fromMessage(
      ExternalPluginRuntimeRequest.retryResource(
        requestId: 'retry-1',
        externalSourceId: 'fixture',
        uri: uri,
      ).toMessage(),
    );

    expect(resolved.operation, ExternalPluginRuntimeOperation.resolveResource);
    expect(retried.operation, ExternalPluginRuntimeOperation.retryResource);
    expect(resolved.arguments['uri'], uri.toString());
    expect(retried.arguments['uri'], uri.toString());
  });

  test('source handshake round-trips ratings without runtime code', () {
    final descriptor = ExternalPluginRuntimeSourceDescriptor(
      externalId: 'fixture',
      name: 'Fixture',
      language: 'en',
      website: Uri.parse('https://example.invalid'),
      browserUserAgent: 'fixture-browser-agent',
      contentRatings: const <SourceContentRating>{
        SourceContentRating.safe,
        SourceContentRating.erotica,
      },
    );

    final decoded = ExternalPluginRuntimeSourceDescriptor.fromMessage(
      descriptor.toMessage(),
    );

    expect(decoded.externalId, 'fixture');
    expect(decoded.browserUserAgent, 'fixture-browser-agent');
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
