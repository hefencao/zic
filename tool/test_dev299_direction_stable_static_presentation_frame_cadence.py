#!/usr/bin/env python3
"""Ownership gate for dev.299 direction-stable static projection continuity and Reader frame timing."""
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
    if missing: raise SystemExit(f'FAIL: {path} missing dev.299 tokens: {missing}')
def forbid(path,*tokens):
    text=read(path); found=[t for t in tokens if t in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.299 tokens: {found}')
if current_dev() == 299:
    require('apps/app/pubspec.yaml','version: 0.31.0+299')
    require('apps/app/android/zic-version.properties','versionCode=299')
elif current_dev() < 299:
    raise SystemExit('FAIL: dev.299 gate executed before dev.299')
require('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        '_staticPresentationContinuityIdentity(',
        '(pageIndex - viewport.currentPageIndex).abs() > 2',
        'final target = binding.pipeline.decodeTarget;',
        'retainedStaticIdentity: uploadIdentity == null')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
        'forwardDecodePages: 2','backwardDecodePages: 1')
if current_dev() < 300:
    require('packages/reader/lib/src/reader_view.dart',
            "import 'package:flutter/scheduler.dart';",
            'SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);',
            'SchedulerBinding.instance.removeTimingsCallback(_handleFrameTimings);',
            'TraceEventKind.readerFrameTiming',
            "'frameIntervalMicros': frameIntervalMicros",
            "'buildMicros': timing.buildDuration.inMicroseconds",
            "'rasterMicros': timing.rasterDuration.inMicroseconds")
else:
    require('packages/reader/lib/src/reader_view.dart',
            'ReaderFrameTimingSource? frameTimingSource',
            'source.subscribe(_handleFrameTimings)',
            'TraceEventKind.readerFrameTiming',
            "'frameIntervalMicros': timing.frameIntervalMicros",
            "'buildMicros': timing.buildMicros",
            "'rasterMicros': timing.rasterMicros")
    forbid('packages/reader/lib/src/reader_view.dart',
           "import 'package:flutter/scheduler.dart';",
           'SchedulerBinding.instance.addTimingsCallback',
           'FramePhase.vsyncStart')
require('packages/telemetry/lib/src/trace.dart','readerFrameTiming,')
require('apps/app/lib/debug_trace.dart',
        'event.kind != TraceEventKind.readerFrameTiming',
        'self-sustaining and perturb the very cadence')
require('docs/adr/0278-static-presentation-direction-stable-continuity.md',
        'current±2','不得为了UI连续性新增DecodeDemand','readerFrameTiming')
require('docs/audits/dev299-direction-stable-static-presentation-frame-cadence-audit.md',
        'page14','current变12','readDirection=-1','frameIntervalMicros')
require('docs/SPEC.md','directional decode previous1/next2 policy仍是唯一decode work窗口','`current±2`','`readerFrameTiming`')
if current_dev() == 299:
    require('docs/NEXT_CHAT_HANDOFF.md','# dev.299 后续交接','current±2','FrameTiming')
else:
    require('docs/NEXT_CHAT_HANDOFF.md','current±2','FrameTiming')
forbid('packages/local_media_ui/lib/src/local_image_player.dart','PhysicalPixelAlignedPresentation(', 'roundingResidual <= 0.500001')
print('dev.299 direction-stable static presentation + frame cadence: OK')
