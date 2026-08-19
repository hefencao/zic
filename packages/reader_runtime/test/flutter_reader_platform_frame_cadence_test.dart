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
    var summaryDrained = false;
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
        case 'drainFrameCadenceSummary':
          if (summaryDrained) return null;
          summaryDrained = true;
          return <String, Object?>{
            'firstFrameTimeNanos': 1000000,
            'lastFrameTimeNanos': 1030000,
            'frameIntervalCount': 3,
            'frameGapSumMicros': 50000,
            'minFrameGapMicros': 8333,
            'maxFrameGapMicros': 25000,
            'gapLt10msCount': 1,
            'gap10To14msCount': 0,
            'gap14To18msCount': 1,
            'gap18To20msCount': 0,
            'gap20To25msCount': 0,
            'gap25To35msCount': 1,
            'gapGe35msCount': 0,
            'displayRefreshRateMilliHz': 120000,
            'frameRatePolicyRequested': 0,
            'displayHasArrSupport': 1,
          };
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
        'drainFrameCadenceSummary',
        'stopFrameCadenceProbe',
        'drainFrameCadenceSummary',
      ]),
    );
    expect(sink.events, hasLength(2));
    final outlier = sink.events[0];
    expect(outlier.kind, TraceEventKind.platformFrameCadenceOutlier);
    expect(outlier.monotonicMicros, 2000020);
    expect(outlier.revision, 7);
    expect(outlier.payload['systemFrameGapMicros'], 33333);
    expect(outlier.payload['callbackGapMicros'], 34000);
    expect(outlier.payload['callbackLagMicros'], 5000);
    expect(outlier.payload['callbackOffsetMicros'], 5);
    expect(outlier.payload['threadCpuGapMicros'], 1200);
    expect(outlier.payload['displayRefreshRateMilliHz'], 120000);
    expect(outlier.payload['frameRatePolicyRequested'], isTrue);
    expect(outlier.payload['displayHasArrSupport'], isTrue);

    final summary = sink.events[1];
    expect(summary.kind, TraceEventKind.platformFrameCadenceSummary);
    expect(summary.monotonicMicros, 2000030);
    expect(summary.revision, 7);
    expect(summary.payload['frameIntervalCount'], 3);
    expect(summary.payload['frameGapSumMicros'], 50000);
    expect(summary.payload['minFrameGapMicros'], 8333);
    expect(summary.payload['maxFrameGapMicros'], 25000);
    expect(summary.payload['gapLt10msCount'], 1);
    expect(summary.payload['gap14To18msCount'], 1);
    expect(summary.payload['gap25To35msCount'], 1);
    expect(summary.payload['frameRatePolicyRequested'], isFalse);
    expect(summary.payload['displayHasArrSupport'], isTrue);

  });
}
