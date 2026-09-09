import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/app.dart';
import 'package:zic/startup_platform.dart';

void main() {
  testWidgets('root back confirms then moves Android task to background', (
    tester,
  ) async {
    final exitCalls = <String>[];
    final backgroundCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') {
          exitCalls.add(call.method);
        }
        return null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      startupPlatformChannel,
      (call) async {
        if (call.method == 'moveApplicationToBackground') {
          backgroundCalls.add(call.method);
          return true;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        startupPlatformChannel,
        null,
      );
    });

    await tester.pumpWidget(const App());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('再按一次返回到后台'), findsOneWidget);
    expect(exitCalls, isEmpty);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(backgroundCalls, <String>['moveApplicationToBackground']);
    expect(exitCalls, isEmpty);
  });

  testWidgets('expired confirm window asks for a fresh confirmation', (
    tester,
  ) async {
    final exitCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') {
          exitCalls.add(call.method);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(const App());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('再按一次返回到后台'), findsOneWidget);

    // The snackbar arms its own dismissal only after its entrance animation
    // settles, so advance far enough for both the confirm window and the
    // snackbar lifecycle to finish.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('再按一次返回到后台'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(exitCalls, isEmpty);
    expect(find.text('再按一次返回到后台'), findsOneWidget);
  });
}
