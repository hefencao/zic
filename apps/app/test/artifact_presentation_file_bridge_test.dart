import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/artifact_presentation_file_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(artifactPresentationFileChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('presentation descriptor closes coalesce into one platform batch',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final bridge = AndroidArtifactPresentationFileBridge(channel: channel);

    final first = bridge.close(11);
    final second = bridge.close(12);
    final duplicate = bridge.close(12);
    await Future.wait<void>(<Future<void>>[first, second, duplicate]);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'presentationCloseMany');
    final arguments = calls.single.arguments! as Map<Object?, Object?>;
    expect(arguments['handles'], unorderedEquals(<int>[11, 12]));
  });
}
