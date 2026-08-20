#!/usr/bin/env python3
"""Separate Reader motion cadence from Android Window frame-pipeline latency."""
from __future__ import annotations

import json
import math
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


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, math.ceil(p * len(ordered)) - 1))]


def fmt(value):
    return 'n/a' if value is None else str(round(value))


def main() -> int:
    if len(sys.argv) != 2:
        print(f'usage: {Path(sys.argv[0]).name} TRACE.jsonl', file=sys.stderr)
        return 2
    events = list(load(Path(sys.argv[1])))

    platform = Counter()
    scroll = Counter()
    window = Counter()
    window_outliers = []
    for event in events:
        kind = event.get('kind')
        payload = event.get('payload', {})
        if kind == 'platformFrameCadenceSummary':
            for key in (
                'frameIntervalCount', 'gapLt10msCount', 'gap10To14msCount',
                'gap14To18msCount', 'gap18To20msCount', 'gap20To25msCount',
                'gap25To35msCount', 'gapGe35msCount', 'frameGapSumMicros',
            ):
                platform[key] += int(payload.get(key, 0) or 0)
        elif kind == 'scrollCadenceSummary':
            for key in (
                'intervalCount', 'gapLt10msCount', 'gap10To14msCount',
                'gap14To18msCount', 'gap18To20msCount', 'gap20To25msCount',
                'gap25To35msCount', 'gapGe35msCount', 'dragDrivenCount',
                'ballisticCount',
            ):
                scroll[key] += int(payload.get(key, 0) or 0)
        elif kind == 'platformWindowFrameMetricsSummary':
            for key in (
                'frameCount', 'droppedReports', 'totalDurationSumMicros',
                'unknownDelaySumMicros', 'maxTotalDurationMicros',
                'maxUnknownDelayMicros', 'totalLt8msCount',
                'total8To12msCount', 'total12To20msCount',
                'total20To35msCount', 'totalGe35msCount',
                'unknownLt2msCount', 'unknown2To8msCount',
                'unknownGe8msCount',
            ):
                if key.startswith('max'):
                    window[key] = max(window[key], int(payload.get(key, 0) or 0))
                else:
                    window[key] += int(payload.get(key, 0) or 0)
        elif kind == 'platformWindowFrameMetricsOutlier':
            window_outliers.append(payload)

    print(f'events={len(events)} task_failed={sum(e.get("kind") == "taskFailed" for e in events)}')
    pf = platform['frameIntervalCount']
    if pf:
        print(
            f'platform_intervals={pf} lt10={platform["gapLt10msCount"]} '
            f'14to18={platform["gap14To18msCount"]} ge35={platform["gapGe35msCount"]} '
            f'mean_gap_us={round(platform["frameGapSumMicros"] / pf) if platform["frameGapSumMicros"] else "n/a"}'
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

    wf = window['frameCount']
    if not wf:
        print('window_frame_metrics=unavailable (trace predates dev.319 or listener unavailable)')
        print('verdict=rerun-with-dev319-window-metrics')
        return 0

    print(
        f'window_frame_metrics={wf} dropped_reports={window["droppedReports"]} '
        f'mean_total_us={round(window["totalDurationSumMicros"] / wf)} '
        f'mean_unknown_us={round(window["unknownDelaySumMicros"] / wf)} '
        f'max_total_us={window["maxTotalDurationMicros"]} '
        f'max_unknown_us={window["maxUnknownDelayMicros"]}'
    )
    print(
        f'window_total_bins=<8:{window["totalLt8msCount"]},8-12:{window["total8To12msCount"]},'
        f'12-20:{window["total12To20msCount"]},20-35:{window["total20To35msCount"]},'
        f'>=35:{window["totalGe35msCount"]} '
        f'unknown_bins=<2:{window["unknownLt2msCount"]},2-8:{window["unknown2To8msCount"]},'
        f'>=8:{window["unknownGe8msCount"]}'
    )

    if window_outliers:
        print(f'window_outliers={len(window_outliers)}')
        for key in (
            'totalDurationMicros', 'unknownDelayMicros', 'syncMicros',
            'commandIssueMicros', 'swapBuffersMicros',
        ):
            values = [int(p[key]) for p in window_outliers if isinstance(p.get(key), int)]
            if values:
                print(
                    f'{key}:median={fmt(statistics.median(values))} '
                    f'p95={fmt(percentile(values, .95))} max={max(values)}'
                )
        late = []
        for payload in window_outliers:
            intended = payload.get('intendedVsyncNanos')
            actual = payload.get('vsyncNanos')
            if isinstance(intended, int) and isinstance(actual, int) and intended > 0 and actual > 0:
                late.append(max(0, (actual - intended) // 1000))
        if late:
            print(
                f'vsync_lateness_us:median={fmt(statistics.median(late))} '
                f'p95={fmt(percentile(late, .95))} max={max(late)}'
            )

    unknown_share = window['unknownGe8msCount'] / wf
    long_total_share = (window['total20To35msCount'] + window['totalGe35msCount']) / wf
    if unknown_share >= 0.05:
        verdict = 'android-window-ui-availability-delay-candidate'
    elif long_total_share >= 0.05:
        verdict = 'android-window-sync-command-swap-candidate'
    elif pf and platform['gapGe35msCount'] + platform['gap25To35msCount'] > 0:
        verdict = 'platform-cadence-hole-outside-window-framework-phases'
    else:
        verdict = 'window-pipeline-healthy-next-surfaceflinger-presentation-cadence'
    print(f'verdict={verdict}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
