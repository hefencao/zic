#!/usr/bin/env python3
"""Summarize fixed-position Reader jank and first-time platform texture blits."""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
from typing import Any


def load(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for raw in path.read_text(encoding='utf-8').splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and isinstance(event.get('kind'), str):
            events.append(event)
    events.sort(key=lambda item: int(item.get('t', 0)))
    return events


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('trace', type=Path)
    parser.add_argument('--severe-micros', type=int, default=33000)
    args = parser.parse_args()
    events = load(args.trace)

    scroll = [e for e in events if e['kind'] == 'scrollCadenceOutlier']
    ballistic = [e for e in scroll if e.get('payload', {}).get('dragDriven') is False]
    by_index = collections.Counter(
        e.get('payload', {}).get('currentIndex') for e in scroll
    )
    severe = [
        e for e in ballistic
        if int(e.get('payload', {}).get('gapMicros', 0)) >= args.severe_micros
    ]

    role_uploads = [
        e for e in events
        if e['kind'] == 'frameUploaded' and 'role' in e.get('payload', {})
    ]
    platform_uploads = [
        e for e in events
        if e['kind'] == 'frameUploaded' and 'blitMicros' in e.get('payload', {})
    ]
    paired: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for platform in platform_uploads:
        identity = platform.get('identityHash')
        candidates = [
            role for role in role_uploads
            if role.get('identityHash') == identity
            and 0 <= int(platform['t']) - int(role['t']) <= 100000
        ]
        if candidates:
            paired.append((platform, max(candidates, key=lambda e: int(e['t']))))

    role_counts = collections.Counter(
        role.get('payload', {}).get('role') for _, role in paired
    )
    next_blits = [
        int(platform.get('payload', {}).get('blitMicros', 0))
        for platform, role in paired
        if role.get('payload', {}).get('role') in {'next', 'next2'}
    ]

    print(f'events={len(events)}')
    print(f'scroll_outliers={len(scroll)} ballistic={len(ballistic)} severe_ballistic={len(severe)}')
    print('scroll_outliers_by_current_index=' + ','.join(
        f'{index}:{count}' for index, count in by_index.most_common()
    ))
    print('paired_platform_upload_roles=' + ','.join(
        f'{role}:{count}' for role, count in role_counts.most_common()
    ))
    if next_blits:
        print(
            f'next_or_next2_platform_blit_micros_max={max(next_blits)} '
            f'count={len(next_blits)}'
        )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
