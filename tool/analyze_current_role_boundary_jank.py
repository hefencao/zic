#!/usr/bin/env python3
"""Compare Pipeline control cost at page-current role promotions vs steady control."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

WINDOW_US = 20_000
POST_RECONCILE_US = 3_000
BUDGET_120HZ_US = 8_333


def load(path: Path) -> list[dict]:
    events: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                value = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                events.append(value)
    return events


def median(values: list[int]) -> int:
    return int(statistics.median(values)) if values else 0


def payload_int(event: dict, name: str) -> int:
    value = (event.get("payload") or {}).get(name)
    return int(value) if isinstance(value, int) else 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()
    events = load(args.trace)

    failures = [event for event in events if event.get("kind") == "taskFailed"]
    currents = [event for event in events if event.get("kind") == "pageCurrent"]
    promotions = currents[1:]
    reconciles = [
        event for event in events if event.get("kind") == "pipelineReconcileTiming"
    ]

    used: set[int] = set()
    boundaries: list[tuple[dict, dict]] = []
    for current in promotions:
        current_t = int(current.get("t") or 0)
        candidates = [
            (index, reconcile)
            for index, reconcile in enumerate(reconciles)
            if index not in used
            and 0 <= int(reconcile.get("t") or 0) - current_t <= WINDOW_US
        ]
        if not candidates:
            continue
        index, reconcile = min(candidates, key=lambda item: int(item[1].get("t") or 0))
        used.add(index)
        boundaries.append((current, reconcile))

    boundary_us = [payload_int(reconcile, "reconcileMicros") for _, reconcile in boundaries]
    other_us = [
        payload_int(reconcile, "reconcileMicros")
        for index, reconcile in enumerate(reconciles)
        if index not in used
    ]

    def med_field(name: str) -> int:
        return median([payload_int(reconcile, name) for _, reconcile in boundaries])

    transitions = [event for event in events if event.get("kind") == "pageTransition"]
    current_coverages: list[float] = []
    target_coverages: list[float] = []
    upload_counts: list[int] = []
    decode_counts: list[int] = []
    for current, reconcile in boundaries:
        current_t = int(current.get("t") or 0)
        prior_transitions = [
            event
            for event in transitions
            if 0 <= current_t - int(event.get("t") or 0) <= 3_000
        ]
        if prior_transitions:
            transition = max(prior_transitions, key=lambda event: int(event.get("t") or 0))
            payload = transition.get("payload") or {}
            current_coverage = payload.get("currentCoverage")
            target_coverage = payload.get("targetCoverage")
            if isinstance(current_coverage, (int, float)):
                current_coverages.append(float(current_coverage))
            if isinstance(target_coverage, (int, float)):
                target_coverages.append(float(target_coverage))
        start = int(current.get("t") or 0)
        end = int(reconcile.get("t") or 0) + POST_RECONCILE_US
        nearby = [event for event in events if start <= int(event.get("t") or 0) <= end]
        upload_counts.append(sum(1 for event in nearby if event.get("kind") == "uploadStarted"))
        decode_counts.append(sum(1 for event in nearby if event.get("kind") == "decodeStarted"))

    boundary_ge_3ms = sum(value >= 3_000 for value in boundary_us)
    other_ge_3ms = sum(value >= 3_000 for value in other_us)
    print(
        f"events={len(events)} page_current={len(currents)} current_promotions={len(promotions)} "
        f"current_boundary_reconciles={len(boundaries)} other_reconciles={len(other_us)} "
        f"task_failed={len(failures)}"
    )
    print(
        "current_boundary_reconcile="
        f"median_us={median(boundary_us)} max_us={max(boundary_us) if boundary_us else 0} "
        f"ge_3000={boundary_ge_3ms}/{len(boundary_us)} budget_120hz_us={BUDGET_120HZ_US}"
    )
    print(
        "other_reconcile="
        f"median_us={median(other_us)} max_us={max(other_us) if other_us else 0} "
        f"ge_3000={other_ge_3ms}/{len(other_us)}"
    )
    print(
        "current_boundary_churn="
        f"download={med_field('downloadAdded')}/{med_field('downloadChanged')}/{med_field('downloadRemoved')} "
        f"decode={med_field('decodeAdded')}/{med_field('decodeChanged')}/{med_field('decodeRemoved')} "
        f"upload={med_field('uploadAdded')}/{med_field('uploadChanged')}/{med_field('uploadRemoved')}"
    )
    if current_coverages and target_coverages:
        print(
            "current_boundary_coverage="
            f"samples={len(current_coverages)} "
            f"current_median={statistics.median(current_coverages):.3f} "
            f"current_min={min(current_coverages):.3f} current_max={max(current_coverages):.3f} "
            f"target_median={statistics.median(target_coverages):.3f}"
        )
    print(
        "current_boundary_lane_starts="
        f"upload_median={median(upload_counts)} upload_total={sum(upload_counts)} "
        f"decode_median={median(decode_counts)} decode_total={sum(decode_counts)}"
    )
    if failures:
        print("verdict=invalid-run-task-failures")
    elif boundaries and median(boundary_us) >= 3_000 and median(other_us) * 3 < median(boundary_us):
        print("verdict=current-role-promotion-control-plane-spike")
    elif boundaries:
        print("verdict=current-role-boundary-not-dominant")
    else:
        print("verdict=no-current-role-boundary-evidence")


if __name__ == "__main__":
    main()
