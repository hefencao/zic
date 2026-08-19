#!/usr/bin/env python3
"""Summarize frame cadence vs visible-motion presentation evidence.

This audit deliberately separates Android Choreographer cadence, Flutter
FrameTiming and Reader scroll-update cadence. It is meant for cases where
DevTools Build/Layout/Paint/Raster are cheap but motion still looks uneven.
"""
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


def weighted_median(values):
    ordered = sorted(values)
    total = sum(weight for _, weight in ordered)
    if not total:
        return None
    threshold = (total + 1) // 2
    seen = 0
    for value, weight in ordered:
        seen += weight
        if seen >= threshold:
            return value
    return ordered[-1][0]


def weighted_mean(values):
    total = sum(weight for _, weight in values)
    if not total:
        return None
    return round(sum(value * weight for value, weight in values) / total)


def main() -> int:
    if len(sys.argv) != 2:
        print(f'usage: {Path(sys.argv[0]).name} TRACE.jsonl', file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    events = list(load(path))

    platform = Counter()
    platform_max = 0
    display_rates = Counter()
    for event in events:
        if event.get('kind') != 'platformFrameCadenceSummary':
            continue
        payload = event.get('payload', {})
        for key in (
            'frameIntervalCount', 'gapLt10msCount', 'gap10To14msCount',
            'gap14To18msCount', 'gap18To20msCount', 'gap20To25msCount',
            'gap25To35msCount', 'gapGe35msCount',
        ):
            platform[key] += int(payload.get(key, 0) or 0)
        platform_max = max(platform_max, int(payload.get('maxFrameGapMicros', 0) or 0))
        rate = payload.get('displayRefreshRateMilliHz')
        if rate is not None:
            display_rates[int(rate)] += int(payload.get('frameIntervalCount', 0) or 0)

    frame_windows = []
    severe = []
    for event in events:
        if event.get('kind') != 'readerFrameTiming':
            continue
        payload = event.get('payload', {})
        if payload.get('timingSummary'):
            count = int(payload.get('frameSampleCount', 0) or 0)
            representative = payload.get('frameIntervalMicros')
            if count > 0 and representative is not None:
                frame_windows.append((int(representative), count))
        else:
            interval = payload.get('frameIntervalMicros')
            if interval is not None and int(interval) >= 20000:
                severe.append(payload)

    scroll = Counter()
    scroll_means = []
    scroll_max = 0
    for event in events:
        if event.get('kind') != 'scrollCadenceSummary':
            continue
        payload = event.get('payload', {})
        count = int(payload.get('intervalCount', 0) or 0)
        for key in (
            'intervalCount', 'gapLt10msCount', 'gap10To14msCount',
            'gap14To18msCount', 'gap18To20msCount', 'gap20To25msCount',
            'gap25To35msCount', 'gapGe35msCount', 'dragDrivenCount',
            'ballisticCount',
        ):
            scroll[key] += int(payload.get(key, 0) or 0)
        mean = payload.get('gapMeanMicros')
        if count > 0 and mean is not None:
            scroll_means.append((int(mean), count))
        scroll_max = max(scroll_max, int(payload.get('maxGapMicros', 0) or 0))

    static_projection = [
        event for event in events if event.get('kind') == 'staticFlutterPresentation'
    ]
    task_failed = sum(1 for event in events if event.get('kind') == 'taskFailed')

    total_platform = platform['frameIntervalCount']
    lt10_share = (
        platform['gapLt10msCount'] / total_platform if total_platform else 0.0
    )
    print(f'events={len(events)} task_failed={task_failed}')
    if total_platform:
        print(
            'platform_frames=' f'{total_platform} '
            f'lt10={platform["gapLt10msCount"]} '
            f'lt10_share={lt10_share:.4f} '
            f'ge35={platform["gapGe35msCount"]} max_gap_us={platform_max} '
            f'display_rates_millihz={dict(display_rates)}'
        )
    else:
        print('platform_frames=0')

    frame_median = weighted_median(frame_windows)
    print(
        f'flutter_summary_samples={sum(weight for _, weight in frame_windows)} '
        f'weighted_frame_interval_us={frame_median} '
        f'raw_ge20_samples={len(severe)}'
    )
    if severe:
        cheap = sum(
            int(p.get('buildMicros', 10**9) or 10**9) < 3000
            and int(p.get('rasterMicros', 10**9) or 10**9) < 3000
            for p in severe
        )
        print(f'raw_ge20_low_phase_lt3ms={cheap} max_gap_us={max(int(p["frameIntervalMicros"]) for p in severe)}')

    if scroll['intervalCount']:
        print(
            f'scroll_intervals={scroll["intervalCount"]} '
            f'weighted_mean_gap_us={weighted_mean(scroll_means)} '
            f'lt10={scroll["gapLt10msCount"]} '
            f'14to18={scroll["gap14To18msCount"]} '
            f'ge35={scroll["gapGe35msCount"]} max_gap_us={scroll_max}'
        )
    else:
        print('scroll_intervals=unavailable (trace predates dev.318 cadence summaries)')

    print(f'static_flutter_presentations={len(static_projection)}')
    if total_platform and lt10_share >= 0.98 and frame_median is not None and frame_median < 10000:
        print('verdict=frame-cadence-healthy-visible-motion-or-composition-candidate')
    elif severe:
        print('verdict=frame-cadence-holes-remain')
    else:
        print('verdict=insufficient-cadence-evidence')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
