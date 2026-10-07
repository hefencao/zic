import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('transform output body delivery preserves input and source locator', () {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final request = ExternalPluginRuntimeRequest(
      requestId: 'transform-body-request',
      operation: ExternalPluginRuntimeOperation.transformResource,
      externalSourceId: 'fixture',
      arguments: <String, Object?>{
        'uri': 'venera-resource:unchanged',
        'bytes': bytes,
        'bodyDelivery': 'sealed-file-v1',
        '__zicIsolatedModifyImage': 'function modifyImage(image){return image}',
      },
    );
    final decoded = ExternalPluginRuntimeRequest.fromMessage(request.toMessage());
    expect(decoded.arguments['uri'], 'venera-resource:unchanged');
    expect(decoded.arguments['bytes'], bytes);
    expect(decoded.arguments['bodyDelivery'], 'sealed-file-v1');
    for (final invalid in <Object?>['pipe', true, 1]) {
      expect(() => ExternalPluginRuntimeRequest(
        requestId: 'invalid-transform-body',
        operation: ExternalPluginRuntimeOperation.transformResource,
        externalSourceId: 'fixture',
        arguments: <String, Object?>{...request.arguments, 'bodyDelivery': invalid},
      ), throwsFormatException);
    }
  });

  test('sealed body delivery is explicit and does not change resource identity',
      () {
    final request = ExternalPluginRuntimeRequest(
      requestId: 'body-request',
      operation: ExternalPluginRuntimeOperation.loadResource,
      externalSourceId: 'fixture',
      arguments: <String, Object?>{
        'uri': 'mihon:resource:unchanged',
        'bodyDelivery': 'sealed-file-v1',
      },
    );
    final decoded = ExternalPluginRuntimeRequest.fromMessage(
      request.toMessage(),
    );
    expect(decoded.arguments['uri'], 'mihon:resource:unchanged');
    expect(decoded.arguments['bodyDelivery'], 'sealed-file-v1');
    for (final invalid in <Object?>['pipe', true, 1]) {
      expect(
        () => ExternalPluginRuntimeRequest(
          requestId: 'invalid-body-request',
          operation: ExternalPluginRuntimeOperation.loadResource,
          externalSourceId: 'fixture',
          arguments: <String, Object?>{
            'uri': 'mihon:resource:unchanged',
            'bodyDelivery': invalid,
          },
        ),
        throwsFormatException,
      );
    }
  });

  test('runtime requests round-trip through one versioned message schema', () {
    final request = ExternalPluginRuntimeRequest.browse(
      requestId: 'request-7',
      externalSourceId: '1234567890123456789',
      query: 'history',
      offset: 24,
      limit: 24,
      sectionId: 'popular',
      filterState: const <String, Object?>{
        '0': true,
        '1': 2,
        '2': <String, Object?>{'index': 1, 'ascending': false},
      },
      useFilters: true,
    );

    final decoded = ExternalPluginRuntimeRequest.fromMessage(
      request.toMessage(),
    );

    expect(decoded.requestId, 'request-7');
    expect(decoded.operation, ExternalPluginRuntimeOperation.browse);
    expect(decoded.externalSourceId, '1234567890123456789');
    expect(decoded.arguments['query'], 'history');
    expect(decoded.arguments['offset'], 24);
    expect(decoded.arguments['sectionId'], 'popular');
    expect(decoded.arguments['useFilters'], isTrue);
    expect(
      decoded.arguments['filterState'],
      <String, Object?>{
        '0': true,
        '1': 2,
        '2': <String, Object?>{'index': 1, 'ascending': false},
      },
    );
  });

  test('browse schema v1 accepts requests created before useFilters', () {
    final decoded = ExternalPluginRuntimeRequest.fromMessage(
      <String, Object?>{
        'schemaVersion': 1,
        'requestId': 'legacy-browse-1',
        'operation': 'browse',
        'externalSourceId': 'fixture',
        'arguments': <String, Object?>{
          'query': '',
          'offset': 0,
          'limit': 24,
          'sectionId': 'popular',
          'filterState': <String, Object?>{},
        },
      },
    );

    expect(decoded.operation, ExternalPluginRuntimeOperation.browse);
    expect(decoded.arguments.containsKey('useFilters'), isFalse);
  });

  test('browse filter mode remains typed and rejects unknown wire fields', () {
    expect(
      () => ExternalPluginRuntimeRequest(
        requestId: 'browse-invalid-filter-mode',
        operation: ExternalPluginRuntimeOperation.browse,
        externalSourceId: 'fixture',
        arguments: <String, Object?>{
          'query': '',
          'offset': 0,
          'limit': 24,
          'sectionId': 'popular',
          'filterState': <String, Object?>{},
          'useFilters': 'yes',
        },
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ExternalPluginRuntimeRequest(
        requestId: 'browse-unknown-field',
        operation: ExternalPluginRuntimeOperation.browse,
        externalSourceId: 'fixture',
        arguments: <String, Object?>{
          'query': '',
          'offset': 0,
          'limit': 24,
          'sectionId': 'popular',
          'filterState': <String, Object?>{},
          'useFilters': false,
          'unexpected': true,
        },
      ),
      throwsA(isA<FormatException>()),
    );
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

  test('source login accepts platform-decoded nested maps', () {
    final decoded = ExternalPluginRuntimeRequest.fromMessage(
      <String, Object?>{
        'schemaVersion': 1,
        'requestId': 'login-1',
        'operation': 'loginSourceAccount',
        'externalSourceId': 'fixture',
        'arguments': <String, Object?>{
          'mode': 'web',
          'values': <Object?, Object?>{
            'currentUrl': 'https://example.invalid/login',
            'cookies': <Object?, Object?>{'igneous': 'session'},
          },
        },
      },
    );

    expect(decoded.operation, ExternalPluginRuntimeOperation.loginSourceAccount);
    expect(
      decoded.arguments['values'],
      isA<Map<Object?, Object?>>(),
    );
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
    final refreshed = ExternalPluginRuntimeRequest.fromMessage(
      ExternalPluginRuntimeRequest.retryResource(
        requestId: 'refresh-1',
        externalSourceId: 'fixture',
        uri: uri,
        freshGeneration: true,
      ).toMessage(),
    );

    expect(resolved.operation, ExternalPluginRuntimeOperation.resolveResource);
    expect(retried.operation, ExternalPluginRuntimeOperation.retryResource);
    expect(refreshed.operation, ExternalPluginRuntimeOperation.retryResource);
    expect(resolved.arguments['uri'], uri.toString());
    expect(retried.arguments['uri'], uri.toString());
    expect(retried.arguments.containsKey('freshGeneration'), isFalse);
    expect(refreshed.arguments['uri'], uri.toString());
    expect(refreshed.arguments['freshGeneration'], isTrue);
  });

  test('source handshake round-trips ratings and adaptive reader hint', () {
    final descriptor = ExternalPluginRuntimeSourceDescriptor(
      externalId: 'fixture',
      name: 'Fixture',
      language: 'en',
      website: Uri.parse('https://example.invalid'),
      supportsComicPreview: true,
      supportsComicComments: true,
      browserUserAgent: 'fixture-browser-agent',
      adaptiveReaderType: SourceAdaptiveReaderType.vertical,
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
    expect(decoded.supportsComicPreview, isTrue);
    expect(decoded.supportsComicComments, isTrue);
    expect(decoded.adaptiveReaderType, SourceAdaptiveReaderType.vertical);
  });

  test('detail preview and comment requests validate nullable cursors', () {
    final preview = ExternalPluginRuntimeRequest.loadComicPreview(
      requestId: 'preview-1',
      externalSourceId: 'fixture',
      comicId: 'comic-1',
    );
    final comments = ExternalPluginRuntimeRequest.loadComicComments(
      requestId: 'comments-1',
      externalSourceId: 'fixture',
      comicId: 'comic-1',
      subId: 'sub-1',
      page: 2,
      replyTo: 'comment-1',
    );
    expect(preview.operation, ExternalPluginRuntimeOperation.loadComicPreview);
    expect(comments.operation, ExternalPluginRuntimeOperation.loadComicComments);
    expect(comments.arguments['page'], 2);
  });

  test('source documents are explicit HTTP binary resources', () {
    final request = ExternalPluginRuntimeRequest(
      requestId: 'version-document',
      operation: ExternalPluginRuntimeOperation.loadResource,
      externalSourceId: 'fixture',
      arguments: const <String, Object?>{
        'uri': 'https://gallery.invalid/g/1/token/',
        'sourceDocument': true,
      },
    );
    expect(request.arguments['sourceDocument'], isTrue);
    expect(
      ExternalPluginRuntimeRequest.loadResource(
        requestId: 'document-factory',
        externalSourceId: 'fixture',
        uri: Uri.parse('https://gallery.invalid/g/1/token/'),
        sourceDocument: true,
      ).arguments,
      request.arguments,
    );
    expect(
      ExternalPluginRuntimeRequest.loadResource(
        requestId: 'image-default',
        externalSourceId: 'fixture',
        uri: Uri.parse('https://gallery.invalid/image.jpg'),
      ).arguments,
      <String, Object?>{'uri': 'https://gallery.invalid/image.jpg'},
    );
    expect(
      ExternalPluginRuntimeRequest.fromMessage(request.toMessage()).arguments,
      request.arguments,
    );
    for (final arguments in <Map<String, Object?>>[
      {'uri': 'https://gallery.invalid/g/1/token/', 'sourceDocument': 'true'},
      {'uri': 'venera-resource:opaque', 'sourceDocument': true},
      {'uri': 'file:///tmp/document', 'sourceDocument': true},
    ]) {
      expect(
        () => ExternalPluginRuntimeRequest(
          requestId: 'invalid-document',
          operation: ExternalPluginRuntimeOperation.loadResource,
          externalSourceId: 'fixture',
          arguments: arguments,
        ),
        throwsFormatException,
      );
    }
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
  test('search filter discovery uses an argument-free runtime request', () {
    final request = ExternalPluginRuntimeRequest.loadSearchFilters(
      requestId: 'filters-1',
      externalSourceId: 'fixture',
    );
    final decoded = ExternalPluginRuntimeRequest.fromMessage(request.toMessage());

    expect(decoded.operation, ExternalPluginRuntimeOperation.loadSearchFilters);
    expect(decoded.arguments, isEmpty);
  });
}
