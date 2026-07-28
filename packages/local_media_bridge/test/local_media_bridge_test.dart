import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_bridge/local_media_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(localMediaBridgeChannelName);
  const bridge = LocalMediaBridge(channel: channel);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
