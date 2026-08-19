#!/usr/bin/env python3
"""Summarize cadence misses whose Flutter build/raster phases stay cheap."""
from __future__ import annotations
import argparse
import json
from pathlib import Path


def load(path: Path):
    with path.open('r', encoding='utf-8') as handle:
        for line in handle:
            line=line.strip()
            if not line:
                continue
            try:
                event=json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                yield event


def main() -> None:
    ap=argparse.ArgumentParser()
    ap.add_argument('trace', type=Path)
    args=ap.parse_args()
    events=list(load(args.trace))
    raw=[]
    for event in events:
        if event.get('kind') != 'readerFrameTiming':
            continue
        payload=event.get('payload') or {}
        if payload.get('timingSummary'):
            continue
        raw.append(payload)
    misses=[p for p in raw if int(p.get('frameIntervalMicros') or 0) >= 20_000]
    low3=[p for p in misses if int(p.get('buildMicros') or 10**12) < 3_000 and int(p.get('rasterMicros') or 10**12) < 3_000]
    low1=[p for p in misses if int(p.get('buildMicros') or 10**12) < 1_000 and int(p.get('rasterMicros') or 10**12) < 1_000]
    counts={}
    for kind in ('scrollCadenceOutlier','platformFrameCadenceOutlier','pipelineReconcileTiming'):
        counts[kind]=sum(1 for e in events if e.get('kind') == kind)
    print(f'events={len(events)} raw_reader_frame_timings={len(raw)}')
    print(f'frame_interval_ge_20ms={len(misses)}')
    print(f'low_phase_build_raster_lt3ms={len(low3)}')
    print(f'strict_build_raster_lt1ms={len(low1)}')
    print(f"scroll_outliers={counts['scrollCadenceOutlier']} platform_frame_outliers={counts['platformFrameCadenceOutlier']} reconciles={counts['pipelineReconcileTiming']}")
    if misses:
        ratio=len(low3)/len(misses)
        print(f'low_phase_share={ratio:.3f}')
        print('verdict=' + ('frame-between-control-candidate' if ratio >= 0.5 else 'framework-phase-cost-still-material'))
    else:
        print('verdict=no-20ms-reader-frame-interval-samples')

if __name__ == '__main__':
    main()
