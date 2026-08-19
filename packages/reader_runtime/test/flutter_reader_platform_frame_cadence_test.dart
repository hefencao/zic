import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/src/flutter_reader_platform_frame_cadence.dart';
import 'package:telemetry/telemetry.dart';

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 2000000;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.zic/test_reader_runtime_frame_cadence');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native frame cadence outlier maps onto shared Reader trace clock',
      () async {
    final calls = <String>[];
    var drained = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'startFrameCadenceProbe':
          return <String, Object?>{'nativeAnchorNanos': 1000000};
        case 'drainFrameCadenceProbe':
          if (drained) return <Object?>[];
          drained = true;
          return <Object?>[
            <String, Object?>{
              'frameTimeNanos': 1020000,
              'callbackNanos': 1025000,
              'frameGapMicros': 33333,
              'callbackGapMicros': 34000,
              'callbackLagMicros': 5000,
              'threadCpuGapMicros': 1200,
              'displayRefreshRateMilliHz': 120000,
              'frameRatePolicyRequested': 1,
              'displayHasArrSupport': 1,
            },
          ];
        case 'stopFrameCadenceProbe':
          return <Object?>[];
      }
      return null;
    });

    final sink = MemoryTraceSink();
    final probe = FlutterReaderPlatformFrameCadenceProbe(
      clock: _Clock(),
      traceSink: sink,
      sessionId: 'reader-1',
      revision: () => 7,
      channel: channel,
      drainInterval: const Duration(hours: 1),
    );

    await probe.start();
    await probe.drain();
    await probe.stop();

    expect(
      calls,
      containsAllInOrder(<String>[
        'startFrameCadenceProbe',
        'drainFrameCadenceProbe',
        'stopFrameCadenceProbe',
      ]),
    );
    expect(sink.events, hasLength(1));
    final event = sink.events.single;
    expect(event.kind, TraceEventKind.platformFrameCadenceOutlier);
    expect(event.monotonicMicros, 2000020);
    expect(event.revision, 7);
    expect(event.payload['systemFrameGapMicros'], 33333);
    expect(event.payload['callbackGapMicros'], 34000);
    expect(event.payload['callbackLagMicros'], 5000);
    expect(event.payload['callbackOffsetMicros'], 5);
    expect(event.payload['threadCpuGapMicros'], 1200);
    expect(event.payload['displayRefreshRateMilliHz'], 120000);
    expect(event.payload['frameRatePolicyRequested'], isTrue);
    expect(event.payload['displayHasArrSupport'], isTrue);
  });
}
