#!/usr/bin/env python3
"""Separate 120 Hz motion delivery from final Flutter scene-transform continuity."""
from __future__ import annotations

import json
import statistics
import sys
from collections import Counter
from pathlib import Path


def load(path: Path):
    with path.open('r', encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line)


def aggregate(events, kind, keys):
    total = Counter()
    for event in events:
        if event.get('kind') != kind:
            continue
        payload = event.get('payload', {}) or {}
        for key in keys:
            total[key] += int(payload.get(key, 0) or 0)
    return total


def dedupe_window_outliers(events):
    unique = []
    seen = set()
    for event in events:
        if event.get('kind') != 'platformWindowFrameMetricsOutlier':
            continue
        payload = event.get('payload', {}) or {}
        key = payload.get('vsyncNanos')
        if not isinstance(key, int) or key <= 0:
            key = (
                payload.get('callbackNanos'),
                payload.get('totalDurationMicros'),
                payload.get('unknownDelayMicros'),
            )
        if key in seen:
            continue
        seen.add(key)
        unique.append(event)
    return unique


def main() -> int:
    if len(sys.argv) != 2:
        print(f'usage: {Path(sys.argv[0]).name} TRACE.jsonl', file=sys.stderr)
        return 2
    events = list(load(Path(sys.argv[1])))
    task_failed = sum(e.get('kind') == 'taskFailed' for e in events)
    platform = aggregate(events, 'platformFrameCadenceSummary', (
        'frameIntervalCount', 'frameGapSumMicros', 'gapLt10msCount',
        'gap10To14msCount', 'gap14To18msCount', 'gap18To20msCount',
        'gap20To25msCount', 'gap25To35msCount', 'gapGe35msCount',
    ))
    scroll = aggregate(events, 'scrollCadenceSummary', (
        'intervalCount', 'gapLt10msCount', 'gap10To14msCount',
        'gap14To18msCount', 'gap18To20msCount', 'gap20To25msCount',
        'gap25To35msCount', 'gapGe35msCount', 'dragDrivenCount',
        'ballisticCount',
    ))
    scene = aggregate(events, 'verticalSceneMotionSummary', (
        'sampleCount', 'validSampleCount', 'missingRenderBoxCount',
        'frameIntervalCount', 'gapLt10msCount', 'gap10To14msCount',
        'gap14To18msCount', 'gap18To20msCount', 'gap20To25msCount',
        'gap25To35msCount', 'gapGe35msCount', 'movingSampleCount',
        'dragSampleCount', 'ballisticSampleCount', 'stationaryBallisticCount',
        'residualOutlierCount',
    ))
    scene_summaries = [
        e.get('payload', {}) or {} for e in events
        if e.get('kind') == 'verticalSceneMotionSummary'
    ]
    scene_outliers = [
        e.get('payload', {}) or {} for e in events
        if e.get('kind') == 'verticalSceneMotionOutlier'
    ]

    print(f'events={len(events)} task_failed={task_failed}')
    pf = platform['frameIntervalCount']
    if pf:
        mean = round(platform['frameGapSumMicros'] / pf) if platform['frameGapSumMicros'] else 'n/a'
        print(
            f'platform_intervals={pf} lt10={platform["gapLt10msCount"]} '
            f'14to18={platform["gap14To18msCount"]} ge35={platform["gapGe35msCount"]} '
            f'mean_gap_us={mean}'
        )
    else:
        print('platform_intervals=0')
    sf = scroll['intervalCount']
    if sf:
        print(
            f'scroll_intervals={sf} lt10={scroll["gapLt10msCount"]} '
            f'14to18={scroll["gap14To18msCount"]} ge35={scroll["gapGe35msCount"]} '
            f'drag={scroll["dragDrivenCount"]} ballistic={scroll["ballisticCount"]}'
        )
    else:
        print('scroll_intervals=0')

    first_active_scroll = None
    for event in events:
        if event.get('kind') != 'readerObservation':
            continue
        interaction = (event.get('payload', {}) or {}).get('interaction')
        if interaction in ('dragging', 'scrolling', 'scrubbing'):
            first_active_scroll = int(event.get('t', 0) or 0)
            break
    window_unique = dedupe_window_outliers(events)
    active_window = [
        e for e in window_unique
        if first_active_scroll is not None and int(e.get('t', 0) or 0) >= first_active_scroll
    ]
    raw_window = sum(e.get('kind') == 'platformWindowFrameMetricsOutlier' for e in events)
    window_frames = sum(
        int((e.get('payload', {}) or {}).get('frameCount', 0) or 0)
        for e in events if e.get('kind') == 'platformWindowFrameMetricsSummary'
    )
    print(
        f'window_metrics_frames={window_frames} raw_outliers={raw_window} '
        f'unique_outliers={len(window_unique)} active_scroll_unique_outliers={len(active_window)}'
    )

    if not scene_summaries:
        print('scene_motion=unavailable (trace predates dev.320)')
        if pf and platform['gapLt10msCount'] / pf >= 0.95 and sf and scroll['gapLt10msCount'] / sf >= 0.90:
            print('verdict=healthy-120hz-supply-rerun-with-dev320-scene-motion')
        else:
            print('verdict=rerun-with-dev320-scene-motion')
        return 0

    max_residual = max(
        (float(p.get('maxAbsLayoutResidualDeltaPx', 0) or 0) for p in scene_summaries),
        default=0.0,
    )
    print(
        f'scene_samples={scene["sampleCount"]} valid={scene["validSampleCount"]} '
        f'missing={scene["missingRenderBoxCount"]} frame_intervals={scene["frameIntervalCount"]} '
        f'lt10={scene["gapLt10msCount"]} 14to18={scene["gap14To18msCount"]} '
        f'ge35={scene["gapGe35msCount"]}'
    )
    print(
        f'scene_moving={scene["movingSampleCount"]} '
        f'drag={scene["dragSampleCount"]} ballistic={scene["ballisticSampleCount"]} '
        f'stationary_ballistic={scene["stationaryBallisticCount"]} '
        f'residual_outliers={scene["residualOutlierCount"]} '
        f'max_abs_residual_delta_px={max_residual:.4f} '
        f'outlier_events={len(scene_outliers)}'
    )
    residual_deltas = [
        abs(float(p['layoutResidualDeltaPx'])) for p in scene_outliers
        if isinstance(p.get('layoutResidualDeltaPx'), (int, float))
    ]
    if residual_deltas:
        print(
            f'residual_event_delta_px_median={statistics.median(residual_deltas):.4f} '
            f'max={max(residual_deltas):.4f}'
        )

    valid = scene['validSampleCount']
    if valid == 0:
        verdict = 'scene-probe-no-valid-renderbox-samples'
    elif scene['residualOutlierCount'] > max(2, valid // 100):
        verdict = 'flutter-scene-transform-discontinuity-candidate'
    elif scene['stationaryBallisticCount'] > max(3, scene['ballisticSampleCount'] // 50):
        verdict = 'flutter-scene-position-repeat-candidate'
    elif pf and platform['gapLt10msCount'] / pf >= 0.95:
        verdict = 'flutter-scene-motion-continuous-next-actual-presentation'
    else:
        verdict = 'scene-motion-continuous-but-platform-cadence-not-clean'
    print(f'verdict={verdict}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
