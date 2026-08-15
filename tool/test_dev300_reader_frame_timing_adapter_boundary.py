#!/usr/bin/env python3
"""Ownership gate for dev.300 Reader FrameTiming adapter boundary."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def current_dev():
    for line in read('apps/app/pubspec.yaml').splitlines():
        if line.startswith('version:') and '+' in line:
            return int(line.rsplit('+',1)[1].strip())
    raise SystemExit('FAIL: app version code missing')
def require(path,*tokens):
    text=read(path); missing=[t for t in tokens if t not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.300 tokens: {missing}')
def forbid(path,*tokens):
    text=read(path); found=[t for t in tokens if t in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.300 tokens: {found}')
if current_dev() == 300:
    require('apps/app/pubspec.yaml','version: 0.31.0+300')
    require('apps/app/android/zic-version.properties','versionCode=300')
elif current_dev() < 300:
    raise SystemExit('FAIL: dev.300 gate executed before dev.300')
require('packages/reader/lib/src/reader_frame_timing.dart',
        'final class ReaderFrameTimingSample',
        'abstract interface class ReaderFrameTimingSource',
        'abstract interface class ReaderFrameTimingSubscription',
        'ReaderFrameTimingSubscription subscribe')
require('packages/reader/lib/src/reader_view.dart',
        'ReaderFrameTimingSource? frameTimingSource',
        '_attachFrameTimingSource()',
        '_detachFrameTimingSource()',
        'List<ReaderFrameTimingSample> timings',
        "'vsyncStartMicros': timing.vsyncStartMicros")
forbid('packages/reader/lib/src/reader_view.dart',
       "import 'package:flutter/scheduler.dart';",
       'SchedulerBinding.instance.addTimingsCallback',
       'SchedulerBinding.instance.removeTimingsCallback',
       'FramePhase.vsyncStart',
       'timestampInMicroseconds(')
require('packages/reader_runtime/lib/src/flutter_reader_frame_timing_source.dart',
        "import 'dart:ui' as ui;",
        "import 'package:flutter/scheduler.dart';",
        'SchedulerBinding.instance.addTimingsCallback(handleTimings);',
        'SchedulerBinding.instance.removeTimingsCallback(_callback);',
        'timing.timestampInMicroseconds(ui.FramePhase.vsyncStart)',
        'ReaderFrameTimingSample(')
require('packages/reader_runtime/lib/src/reader_runtime_screen.dart',
        'frameTimingSource: const FlutterReaderFrameTimingSource()')
require('packages/reader_runtime/test/flutter_reader_frame_timing_source_test.dart',
        'ui.FramePhase.vsyncStart',
        'ReaderFrameTimingSample(')
require('docs/adr/0279-reader-frame-timing-adapter-boundary.md',
        'ReaderFrameTimingSource','reader_runtime','FramePhase')
require('docs/audits/dev300-reader-frame-timing-boundary-audit.md',
        'FramePhase.vsyncStart','ReaderRuntimeScreen')
require('docs/SPEC.md','ReaderFrameTimingSample','ReaderView` MUST NOT直接解析engine timing API')
print('dev.300 Reader FrameTiming adapter boundary: OK')
