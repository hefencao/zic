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
    var windowDrained = false;
    var windowSummaryDrained = false;
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
        case 'drainWindowFrameMetricsProbe':
          if (windowDrained) return <Object?>[];
          windowDrained = true;
          return <Object?>[
            <String, Object?>{
              'callbackNanos': 1040000,
              'totalDurationMicros': 23000,
              'unknownDelayMicros': 9000,
              'inputHandlingMicros': 100,
              'animationMicros': 200,
              'layoutMeasureMicros': 300,
              'drawMicros': 400,
              'syncMicros': 500,
              'commandIssueMicros': 600,
              'swapBuffersMicros': 700,
              'droppedReports': 2,
              'intendedVsyncNanos': 1030000,
              'vsyncNanos': 1035000,
              'displayRefreshRateMilliHz': 120000,
            },
          ];
        case 'drainWindowFrameMetricsSummary':
          if (windowSummaryDrained) return null;
          windowSummaryDrained = true;
          return <String, Object?>{
            'frameCount': 8,
            'droppedReports': 2,
            'totalDurationSumMicros': 80000,
            'unknownDelaySumMicros': 12000,
            'maxTotalDurationMicros': 23000,
            'maxUnknownDelayMicros': 9000,
            'totalLt8msCount': 3,
            'total8To12msCount': 2,
            'total12To20msCount': 2,
            'total20To35msCount': 1,
            'totalGe35msCount': 0,
            'unknownLt2msCount': 6,
            'unknown2To8msCount': 1,
            'unknownGe8msCount': 1,
            'displayRefreshRateMilliHz': 120000,
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
        'drainWindowFrameMetricsProbe',
        'drainWindowFrameMetricsSummary',
        'stopFrameCadenceProbe',
        'drainFrameCadenceSummary',
        'drainWindowFrameMetricsProbe',
        'drainWindowFrameMetricsSummary',
      ]),
    );
    expect(sink.events, hasLength(4));
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

    final windowOutlier = sink.events[2];
    expect(windowOutlier.kind, TraceEventKind.platformWindowFrameMetricsOutlier);
    expect(windowOutlier.monotonicMicros, 2000035);
    expect(windowOutlier.payload['totalDurationMicros'], 23000);
    expect(windowOutlier.payload['unknownDelayMicros'], 9000);
    expect(windowOutlier.payload['syncMicros'], 500);
    expect(windowOutlier.payload['swapBuffersMicros'], 700);
    expect(windowOutlier.payload['droppedReports'], 2);
    expect(windowOutlier.payload['displayRefreshRateMilliHz'], 120000);

    final windowSummary = sink.events[3];
    expect(windowSummary.kind, TraceEventKind.platformWindowFrameMetricsSummary);
    expect(windowSummary.payload['frameCount'], 8);
    expect(windowSummary.payload['droppedReports'], 2);
    expect(windowSummary.payload['maxTotalDurationMicros'], 23000);
    expect(windowSummary.payload['maxUnknownDelayMicros'], 9000);
    expect(windowSummary.payload['unknownGe8msCount'], 1);

  });
}
