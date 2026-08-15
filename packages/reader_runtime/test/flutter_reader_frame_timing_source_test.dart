import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';

void main() {
  test('ReaderFrameTimingSample is framework-neutral cadence data', () {
    const sample = ReaderFrameTimingSample(
      buildMicros: 1200,
      rasterMicros: 2400,
      totalSpanMicros: 5200,
      vsyncOverheadMicros: 300,
      vsyncStartMicros: 100000,
      frameIntervalMicros: 16667,
    );

    expect(sample.buildMicros, 1200);
    expect(sample.rasterMicros, 2400);
    expect(sample.frameIntervalMicros, 16667);
  });

  test('Flutter FramePhase remains a dart:ui adapter concern', () {
    final timing = ui.FrameTiming(
      vsyncStart: 100000,
      buildStart: 100300,
      buildFinish: 101500,
      rasterStart: 101800,
      rasterFinish: 104200,
      rasterFinishWallTime: 104200,
    );

    expect(
      timing.timestampInMicroseconds(ui.FramePhase.vsyncStart),
      100000,
    );
    expect(timing.buildDuration.inMicroseconds, 1200);
    expect(timing.rasterDuration.inMicroseconds, 2400);
  });
}
