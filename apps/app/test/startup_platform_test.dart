import 'package:flutter_test/flutter_test.dart';
import 'package:zic/startup_platform.dart';

void main() {
  testWidgets('Android scheduling snapshot preserves platform evidence', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      startupPlatformChannel,
      (call) async {
        if (call.method != 'runtimeSchedulingSnapshot') return null;
        return <String, Object?>{
          'powerSaveMode': true,
          'processImportance': 100,
          'cpuAllowedList': '0-3',
          'cpusetGroup': '/top-app',
          'cpuGroup': '/top-app',
          'availableProcessors': 8,
        };
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        startupPlatformChannel,
        null,
      );
    });

    final snapshot = await getAndroidSchedulingSnapshot();

    expect(snapshot?['powerSaveMode'], isTrue);
    expect(snapshot?['processImportance'], 100);
    expect(snapshot?['cpuAllowedList'], '0-3');
    expect(snapshot?['cpusetGroup'], '/top-app');
    expect(snapshot?['cpuGroup'], '/top-app');
    expect(snapshot?['availableProcessors'], 8);
  });
}
