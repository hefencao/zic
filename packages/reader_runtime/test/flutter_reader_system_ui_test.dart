import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/src/flutter_reader_system_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android Reader system bars use the native insets owner', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      const startup = MethodChannel('dev.zic.zic/startup');
      const systemUi = MethodChannel('dev.zic/test_reader_runtime_system_ui');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        startup,
        (_) async => null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(systemUi, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      try {
        final owner = FlutterReaderSystemUi(channel: systemUi);
        await owner.apply(showStatusBar: false, showNavigationBar: true);
        await owner.restore();

        expect(calls, hasLength(2));
        expect(calls[0].method, 'setReaderSystemBars');
        expect(calls[0].arguments, <String, Object?>{
          'statusBarVisible': false,
          'navigationBarVisible': true,
        });
        expect(calls[1].method, 'restoreReaderSystemBars');
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          startup,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          systemUi,
          null,
        );
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
