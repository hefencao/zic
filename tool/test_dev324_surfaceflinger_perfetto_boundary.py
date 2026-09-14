#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path):
    return (ROOT / path).read_text(encoding='utf-8')


def require(path, token, reason):
    body = text(path)
    if token not in body:
        raise SystemExit(f'{path}: missing {reason}: {token!r}')


config = 'tool/reader_surfaceflinger_perfetto.pbtxt'
capture = 'tool/capture_reader_surfaceflinger_perfetto.sh'
analyzer = 'tool/analyze_reader_surfaceflinger_perfetto.py'

for token in (
    'android.surfaceflinger.frametimeline',
    'android.surfaceflinger.layers',
    'TRACE_FLAG_COMPOSITION',
    'TRACE_FLAG_BUFFERS',
    'atrace_apps: "dev.zic.zic"',
):
    require(config, token, 'final-presentation Perfetto evidence source')

for token in (
    'SDK < 31',
    'ZIC_PERFETTO_DURATION_MS',
    'adb shell perfetto --txt -c -',
    'Reproduce the fixed-position Reader hitch now',
):
    require(capture, token, 'bounded device capture contract')

for token in (
    'actual_frame_timeline_slice',
    "p.name = 'dev.zic.zic'",
    "p.name = '/system/bin/surfaceflinger'",
    'present_gap_ns',
    'jank_type',
    'present_type',
    'latched_fence_state',
    'actual-presentation-jank-observed',
):
    require(analyzer, token, 'FrameTimeline analysis boundary')

require('CHANGELOG.md', '0.31.0-dev.324', 'changelog version')
print('dev.324 SurfaceFlinger Perfetto evidence boundary: OK')
