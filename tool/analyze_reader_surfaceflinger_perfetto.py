#!/usr/bin/env python3
"""Summarize final app/SurfaceFlinger presentation cadence from a Perfetto trace.

This is observation-only. It intentionally does not infer Reader/Pipeline policy from
FrameTimeline. The primary question is whether a visually reproduced hitch is visible
at the final presentation/composition boundary after Flutter scene motion is healthy.
"""
from __future__ import annotations

import argparse
import csv
import io
import os
import shutil
import subprocess
import sys
from pathlib import Path

PACKAGE = 'dev.zic.zic'

QUERY = r'''
SELECT
  COUNT(*) AS app_actual_frames,
  SUM(CASE WHEN LOWER(COALESCE(jank_type, 'none')) != 'none' THEN 1 ELSE 0 END) AS app_janky_frames,
  SUM(CASE WHEN LOWER(COALESCE(present_type, '')) LIKE '%late%' THEN 1 ELSE 0 END) AS app_late_frames,
  SUM(CASE WHEN COALESCE(on_time_finish, 1) = 0 THEN 1 ELSE 0 END) AS app_late_finish_frames,
  COUNT(DISTINCT layer_name) AS app_layer_count,
  SUM(CASE WHEN LOWER(COALESCE(layer_name, '')) LIKE '%surfaceview%'
           THEN 1 ELSE 0 END) AS app_content_frames
FROM actual_frame_timeline_slice a
JOIN process p USING (upid)
WHERE p.name = 'dev.zic.zic' AND a.surface_frame_token != 0;

WITH frames AS (
  SELECT
    a.layer_name AS layer_name,
    a.ts AS ts,
    a.dur AS dur,
    a.ts + a.dur AS presented_ts,
    a.present_type AS present_type,
    a.jank_type AS jank_type,
    a.on_time_finish AS on_time_finish,
    a.gpu_composition AS gpu_composition
  FROM actual_frame_timeline_slice a
  JOIN process p USING (upid)
  WHERE p.name = 'dev.zic.zic' AND a.surface_frame_token != 0
), ordered AS (
  SELECT
    *,
    presented_ts - LAG(presented_ts) OVER (
      PARTITION BY layer_name ORDER BY presented_ts
    ) AS present_gap_ns
  FROM frames
)
SELECT
  COALESCE(layer_name, '<null>') AS layer_name,
  COUNT(*) AS frames,
  SUM(CASE WHEN present_gap_ns >= 12000000 THEN 1 ELSE 0 END) AS gap_ge_12ms,
  SUM(CASE WHEN present_gap_ns >= 20000000 THEN 1 ELSE 0 END) AS gap_ge_20ms,
  MAX(COALESCE(present_gap_ns, 0)) AS max_present_gap_ns,
  SUM(CASE WHEN LOWER(COALESCE(present_type, '')) LIKE '%late%' THEN 1 ELSE 0 END) AS late_present,
  SUM(CASE WHEN LOWER(COALESCE(jank_type, 'none')) != 'none' THEN 1 ELSE 0 END) AS janky,
  SUM(CASE WHEN COALESCE(on_time_finish, 1) = 0 THEN 1 ELSE 0 END) AS late_finish,
  SUM(CASE WHEN COALESCE(gpu_composition, 0) != 0 THEN 1 ELSE 0 END) AS gpu_composed
FROM ordered
GROUP BY layer_name
ORDER BY gap_ge_20ms DESC, max_present_gap_ns DESC, frames DESC;

SELECT
  COALESCE(a.layer_name, '<null>') AS layer_name,
  a.ts AS ts_ns,
  a.dur AS dur_ns,
  a.present_type AS present_type,
  a.jank_type AS jank_type,
  a.jank_severity_type AS jank_severity_type,
  a.on_time_finish AS on_time_finish,
  a.gpu_composition AS gpu_composition,
  a.latched_fence_state AS latched_fence_state
FROM actual_frame_timeline_slice a
JOIN process p USING (upid)
WHERE p.name = 'dev.zic.zic'
  AND a.surface_frame_token != 0
  AND (
    LOWER(COALESCE(a.jank_type, 'none')) != 'none'
    OR LOWER(COALESCE(a.present_type, '')) LIKE '%late%'
    OR COALESCE(a.on_time_finish, 1) = 0
  )
ORDER BY a.ts
LIMIT 80;

SELECT
  COUNT(*) AS sf_actual_frames,
  SUM(CASE WHEN LOWER(COALESCE(jank_type, 'none')) != 'none' THEN 1 ELSE 0 END) AS sf_janky_frames,
  SUM(CASE WHEN LOWER(COALESCE(present_type, '')) LIKE '%late%' THEN 1 ELSE 0 END) AS sf_late_frames
FROM actual_frame_timeline_slice a
JOIN process p USING (upid)
WHERE p.name = '/system/bin/surfaceflinger'
  AND COALESCE(a.surface_frame_token, 0) = 0;

SELECT name, severity, source, idx, value AS count
FROM stats
WHERE value > 0 AND (
  severity IN ('error', 'data_loss')
  OR name IN ('interned_data_tokenizer_errors',
              'frame_timeline_event_parser_errors', 'traced_buf_chunks_discarded')
)
ORDER BY name, idx;
'''


def split_csv_sets(text: str):
    chunks = [chunk.strip() for chunk in text.split('\n\n') if chunk.strip()]
    return [list(csv.DictReader(io.StringIO(chunk))) for chunk in chunks]


def locate_trace_processor(explicit: str | None) -> str | None:
    if explicit:
        return explicit
    env = os.environ.get('TRACE_PROCESSOR', '').strip()
    if env:
        return env
    return shutil.which('trace_processor') or shutil.which('trace_processor_shell')


def run_query(binary: str, trace: Path) -> str:
    commands = [
        [binary, 'query', str(trace), QUERY],
        [binary, '-q', QUERY, str(trace)],
    ]
    errors = []
    for command in commands:
        completed = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            return completed.stdout
        errors.append(completed.stderr.strip())
    raise RuntimeError('\n'.join(error for error in errors if error))


def as_int(row, key):
    try:
        return int(row.get(key, '0') or 0)
    except (TypeError, ValueError):
        return 0


def evidence_verdict(app, layers, anomalies, integrity):
    if integrity:
        return 'invalid-evidence-trace-loss-or-parser-errors'
    if as_int(app, 'app_actual_frames') == 0:
        return 'no-app-frametimeline-evidence'
    # ZIC's Flutter content is hosted by SurfaceView. Activity/TX window frames
    # alone cannot establish cadence or jank for that independently updated layer.
    if as_int(app, 'app_content_frames') == 0:
        return 'no-app-content-layer-frametimeline-evidence'
    if anomalies:
        return 'actual-presentation-jank-observed'
    if any(as_int(row, 'gap_ge_20ms') for row in layers):
        return 'actual-presentation-gap-observed-without-frametimeline-jank-tag'
    return 'no-final-presentation-jank-in-captured-window'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('trace', type=Path)
    parser.add_argument('--trace-processor')
    args = parser.parse_args()

    if not args.trace.is_file():
        print(f'trace not found: {args.trace}', file=sys.stderr)
        return 2
    processor = locate_trace_processor(args.trace_processor)
    if processor is None:
        print(
            'trace_processor is required. Set TRACE_PROCESSOR or pass '
            '--trace-processor /path/to/trace_processor.',
            file=sys.stderr,
        )
        return 2

    try:
        result_sets = split_csv_sets(run_query(processor, args.trace))
    except RuntimeError as error:
        print(f'trace_processor failed: {error}', file=sys.stderr)
        return 2
    if len(result_sets) < 5:
        print(
            f'unexpected trace_processor output: expected 5 result sets, got {len(result_sets)}',
            file=sys.stderr,
        )
        return 2

    app = result_sets[0][0] if result_sets[0] else {}
    layers = result_sets[1]
    anomalies = result_sets[2]
    sf = result_sets[3][0] if result_sets[3] else {}
    integrity = result_sets[4]

    app_frames = as_int(app, 'app_actual_frames')
    print(
        f'app_frames={app_frames} app_layers={as_int(app, "app_layer_count")} '
        f'app_content_frames={as_int(app, "app_content_frames")} '
        f'app_janky={as_int(app, "app_janky_frames")} '
        f'app_late_present={as_int(app, "app_late_frames")} '
        f'app_late_finish={as_int(app, "app_late_finish_frames")}'
    )
    print(
        f'surfaceflinger_frames={as_int(sf, "sf_actual_frames")} '
        f'surfaceflinger_janky={as_int(sf, "sf_janky_frames")} '
        f'surfaceflinger_late_present={as_int(sf, "sf_late_frames")}'
    )
    print(f'layer_rows={len(layers)} anomaly_rows={len(anomalies)}')
    print(f'integrity_issue_rows={len(integrity)}')
    for row in integrity:
        print(f'trace_issue={row.get("name")} severity={row.get("severity")} '
              f'count={as_int(row, "count")} index={row.get("idx")}')
    for row in layers[:20]:
        max_gap_us = as_int(row, 'max_present_gap_ns') // 1000
        print(
            'layer='
            f'{row.get("layer_name", "<unknown>")} frames={as_int(row, "frames")} '
            f'gap_ge_12ms={as_int(row, "gap_ge_12ms")} '
            f'gap_ge_20ms={as_int(row, "gap_ge_20ms")} '
            f'max_present_gap_us={max_gap_us} '
            f'late_present={as_int(row, "late_present")} '
            f'janky={as_int(row, "janky")} late_finish={as_int(row, "late_finish")} '
            f'gpu_composed={as_int(row, "gpu_composed")}'
        )

    print(f'verdict={evidence_verdict(app, layers, anomalies, integrity)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
