import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/src/flutter_reader_platform_frame_rate_policy.dart';
import 'package:telemetry/telemetry.dart';

final class _Clock implements MonoClock {
  var value = 3000000;

  @override
  int nowMicros() => value++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.zic/test_reader_runtime_frame_rate_policy');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('vertical Reader ARR policy is reader-scoped and restored', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final active = call.arguments is Map<Object?, Object?>
          ? (call.arguments as Map<Object?, Object?>)['active'] == true
          : false;
      return <String, Object?>{
        'sdkInt': 35,
        'requested': active,
        'applied': true,
        'previousBalanced': true,
        'currentBalanced': !active,
        'displayRefreshRateMilliHz': 120000,
        'displayHasArrSupport': true,
        'reason': active ? 'reader-arr-disabled' : 'reader-arr-restored',
      };
    });

    final clock = _Clock();
    final sink = MemoryTraceSink();
    final policy = FlutterReaderPlatformFrameRatePolicy(
      clock: clock,
      traceSink: sink,
      sessionId: 'reader-1',
      revision: () => 9,
      channel: channel,
    );

    await policy.start();
    await policy.stop();

    expect(calls, hasLength(2));
    expect(calls[0].method, 'setVerticalReaderFrameRatePolicy');
    expect((calls[0].arguments as Map<Object?, Object?>)['active'], isTrue);
    expect((calls[1].arguments as Map<Object?, Object?>)['active'], isFalse);
    expect(sink.events, hasLength(2));
    expect(sink.events[0].kind, TraceEventKind.platformFrameRatePolicy);
    expect(sink.events[0].payload['phase'], 'start');
    expect(sink.events[0].payload['currentBalanced'], isFalse);
    expect(sink.events[1].payload['phase'], 'stop');
    expect(sink.events[1].payload['reason'], 'reader-arr-restored');
  });
}
