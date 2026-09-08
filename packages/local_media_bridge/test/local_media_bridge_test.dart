import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_bridge/local_media_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(localMediaBridgeChannelName);
  const startupChannel = MethodChannel('dev.zic.zic/startup');
  const bridge = LocalMediaBridge(channel: channel);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(startupChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('attaches deferred Android plugin before first bridge call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(startupChannel, (call) async {
      calls.add('startup:${call.method}');
      expect(call.method, 'attachPlugin');
      expect(
        call.arguments,
        const <String, Object?>{'name': 'local_media_bridge'},
      );
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add('bridge:${call.method}');
      expect(call.method, 'pickImageDirectory');
      return null;
    });

    expect(await bridge.pickImageDirectory(), isNull);
    expect(calls, <String>[
      'startup:attachPlugin',
      'bridge:pickImageDirectory',
    ]);
  });

  test('scoped directory response preserves document identities', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickImageDirectory');
      return <String, Object?>{
        'protocolVersion': localMediaBridgeProtocolVersion,
        'treeUri': 'content://provider/tree/chapter',
        'displayName': 'chapter',
        'scannedFiles': 3,
        'unreadableFiles': 1,
        'headerRecognizedFiles': 1,
        'metadataRecognizedFiles': 0,
        'documents': <Object?>[
          <String, Object?>{
            'sourceUri': 'content://provider/document/page-1',
            'displayName': 'sub/001.webp',
            'format': 'webp',
            'recognition': 'header',
            'byteLength': 42,
          },
        ],
      };
    });

    final directory = await bridge.pickImageDirectory();

    expect(directory, isNotNull);
    expect(directory!.treeUri, 'content://provider/tree/chapter');
    expect(directory.displayName, 'chapter');
    expect(directory.scannedFiles, 3);
    expect(directory.unreadableFiles, 1);
    expect(directory.headerRecognizedFiles, 1);
    expect(directory.metadataRecognizedFiles, 0);
    expect(directory.unrecognizedFiles, 1);
    expect(directory.documents.single.sourceUri,
        'content://provider/document/page-1');
    expect(directory.documents.single.displayName, 'sub/001.webp');
    expect(directory.documents.single.format, 'webp');
    expect(directory.documents.single.recognition, 'header');
    expect(directory.documents.single.byteLength, 42);
  });


  test('persisted document tree can be rescanned without reopening picker', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'scanImageDirectory');
      expect(
        call.arguments,
        <String, Object?>{
          'treeUri': 'content://provider/tree/chapter',
        },
      );
      return <String, Object?>{
        'protocolVersion': localMediaBridgeProtocolVersion,
        'treeUri': 'content://provider/tree/chapter',
        'displayName': 'chapter',
        'scannedFiles': 1,
        'unreadableFiles': 0,
        'headerRecognizedFiles': 1,
        'metadataRecognizedFiles': 0,
        'documents': <Object?>[
          <String, Object?>{
            'sourceUri': 'content://provider/document/page-2',
            'displayName': '002.png',
            'format': 'png',
            'recognition': 'header',
            'byteLength': 68,
          },
        ],
      };
    });

    final directory = await bridge.scanImageDirectory(
      'content://provider/tree/chapter',
    );
    expect(directory.documents.single.displayName, '002.png');
  });

  test('directory cancellation remains null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    expect(await bridge.pickImageDirectory(), isNull);
  });

  test('document streams pull bounded 256 KiB chunks and close', () async {
    final methods = <String>[];
    var readCount = 0;
    var closeCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'openDocument':
          expect(
            call.arguments,
            <String, Object?>{
              'sourceUri': 'content://provider/document/page-large',
              'start': 4,
              'endExclusive': 9,
              'expectedRevision': 'old-revision',
            },
          );
          return <String, Object?>{
            'handleId': 'handle-1',
            'rangeStart': 4,
            'totalLength': 12,
            'revision': 'current-revision',
            'rangeSupported': true,
            'partial': true,
          };
        case 'readDocumentChunk':
          expect(
            call.arguments,
            <String, Object?>{
              'handleId': 'handle-1',
              'maxBytes': localMediaBridgeChunkBytes,
            },
          );
          return switch (readCount++) {
            0 => Uint8List.fromList(<int>[4, 5, 6]),
            1 => Uint8List.fromList(<int>[7, 8]),
            _ => Uint8List(0),
          };
        case 'closeDocument':
          closeCount++;
          expect(call.arguments, <String, Object?>{'handleId': 'handle-1'});
          return null;
        default:
          fail('unexpected method ${call.method}');
      }
    });

    final response = await bridge.openDocument(
      'content://provider/document/page-large',
      start: 4,
      endExclusive: 9,
      expectedRevision: 'old-revision',
    );
    final bytes = await response.bytes.expand((chunk) => chunk).toList();

    expect(bytes, <int>[4, 5, 6, 7, 8]);
    expect(response.rangeStart, 4);
    expect(response.totalLength, 12);
    expect(response.revision, 'current-revision');
    expect(response.rangeSupported, isTrue);
    expect(response.partial, isTrue);
    expect(closeCount, 1);
    expect(methods.first, 'openDocument');
    expect(methods.last, 'closeDocument');
  });

  test('seekable document descriptor bypasses per-chunk method calls',
      () async {
    final temp = await Directory.systemTemp.createTemp('local_media_fd_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final file = File('${temp.path}/page.webp');
    await file.writeAsBytes(List<int>.generate(16, (index) => index));
    var closeCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'openDocument':
          return <String, Object?>{
            'handleId': 'direct-handle',
            'rangeStart': 4,
            'totalLength': 16,
            'revision': 'direct-revision',
            'rangeSupported': true,
            'partial': true,
            'directPath': file.path,
            'directStart': 4,
            'directEndExclusive': 9,
          };
        case 'readDocumentChunk':
          fail('direct descriptor must not use per-chunk MethodChannel reads');
        case 'closeDocument':
          closeCount++;
          return null;
        default:
          fail('unexpected method ${call.method}');
      }
    });

    final response = await bridge.openDocument(
      'content://provider/document/direct-page',
      start: 4,
      endExclusive: 9,
    );
    final bytes = await response.bytes.expand((chunk) => chunk).toList();

    expect(bytes, <int>[4, 5, 6, 7, 8]);
    expect(closeCount, 1);
  });

  test('document thumbnail request keeps original bytes on the platform side',
      () async {
    final thumbnail = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readDocumentThumbnail');
      expect(
        call.arguments,
        <String, Object?>{
          'sourceUri': 'content://provider/document/large-cover.webp',
          'maxWidth': 512,
          'maxHeight': 768,
        },
      );
      return thumbnail;
    });

    expect(
      await bridge.readDocumentThumbnail(
        'content://provider/document/large-cover.webp',
      ),
      thumbnail,
    );
  });

  test('document thumbnail capability failure falls back to caller policy',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'thumbnail_unavailable');
    });

    expect(
      await bridge.readDocumentThumbnail(
        'content://provider/document/large-cover.webp',
      ),
      isNull,
    );
  });

  test('document reads use the persisted content identity', () async {
    final expected = Uint8List.fromList(<int>[1, 2, 3, 4]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readDocument');
      expect(
        call.arguments,
        <String, Object?>{
          'sourceUri': 'content://provider/document/page-1',
        },
      );
      return expected;
    });

    expect(
      await bridge.readDocument('content://provider/document/page-1'),
      expected,
    );
  });

  test('stale native bridge is rejected with a clean-build instruction', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <String, Object?>{
              'treeUri': 'content://provider/tree/chapter',
              'displayName': 'chapter',
              'scannedFiles': 0,
              'unreadableFiles': 0,
              'documents': <Object?>[],
            });

    await expectLater(
      bridge.pickImageDirectory(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('./tool/clean.sh'),
        ),
      ),
    );
  });

  test('malformed native directory response is rejected', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <String, Object?>{
              'protocolVersion': localMediaBridgeProtocolVersion,
              'treeUri': 'content://provider/tree/chapter',
              'displayName': 'chapter',
              'scannedFiles': 1,
              'unreadableFiles': 0,
              'documents': 'not-a-list',
            });

    await expectLater(
      bridge.pickImageDirectory(),
      throwsA(isA<FormatException>()),
    );
  });
}
