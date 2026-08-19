#!/usr/bin/env python3
"""Summarize dev.315 static encoded-vs-texture presentation evidence."""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('trace', type=Path)
    args = parser.parse_args()

    events = []
    bad = 0
    with args.trace.open('r', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1

    kinds = Counter(event.get('kind') for event in events)
    classified = [e for e in events if e.get('kind') == 'mediaClassified']
    static_classified = [
        e for e in classified
        if e.get('payload', {}).get('animated') is False
        and e.get('payload', {}).get('complete') is True
    ]
    encoded = [e for e in events if e.get('kind') == 'staticEncodedPresentation']
    pipeline = [e for e in events if e.get('kind') == 'framePipelineTiming']
    platform_blits = [
        e for e in pipeline
        if int(e.get('payload', {}).get('platformBlitMicros') or 0) > 0
    ]
    android_texture = [
        e for e in pipeline
        if e.get('payload', {}).get('renderer') == 'androidTexture'
    ]
    outliers = [e for e in events if e.get('kind') == 'scrollCadenceOutlier']

    print(f'events={len(events)} json_errors={bad}')
    print(f'scroll_outliers={len(outliers)}')
    print(f'media_classified={len(classified)} authoritative_static={len(static_classified)}')
    print(f'static_encoded_presentations={len(encoded)}')
    print(f'frame_pipeline_timing={len(pipeline)} android_texture={len(android_texture)} platform_blits={len(platform_blits)}')
    if encoded:
        routes = Counter(e.get('payload', {}).get('route') for e in encoded)
        print('static_encoded_routes=' + ','.join(f'{key}:{value}' for key, value in sorted(routes.items(), key=lambda item: str(item[0]))))
        byte_values = [int(e.get('payload', {}).get('bytes') or 0) for e in encoded]
        print(f'static_encoded_bytes_min={min(byte_values)} max={max(byte_values)}')
    if platform_blits:
        roles = Counter(e.get('payload', {}).get('role') for e in platform_blits)
        print('platform_blit_roles=' + ','.join(f'{key}:{value}' for key, value in sorted(roles.items(), key=lambda item: str(item[0]))))
        values = [int(e.get('payload', {}).get('platformBlitMicros') or 0) for e in platform_blits]
        print(f'platform_blit_micros_max={max(values)}')
    else:
        print('platform_blit_roles=none')
        print('platform_blit_micros_max=0')

    # dev.315 success criterion for a static-only reproduction: encoded static
    # projection should exist and Android texture physical copies should vanish.
    if static_classified and not encoded:
        print('verdict=static-classified-without-encoded-presentation')
    elif encoded and platform_blits:
        print('verdict=encoded-route-active-but-platform-blits-remain-check-animation-identities')
    elif encoded:
        print('verdict=static-encoded-route-active-no-platform-blits')
    else:
        print('verdict=insufficient-static-presentation-evidence')

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
