#!/usr/bin/env python3
"""Summarize resident-static re-presentation around active direction flips."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

ACTIVE = {"dragging", "scrolling", "settling"}
WINDOW_US = 15_000


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()
    events = load(args.trace)

    task_failures = [event for event in events if event.get("kind") == "taskFailed"]
    policies = [event for event in events if event.get("kind") == "policyDecision"]
    timings = [event for event in events if event.get("kind") == "framePipelineTiming"]

    last_direction: int | None = None
    flips: list[dict] = []
    for policy in policies:
        payload = policy.get("payload") or {}
        direction = payload.get("readDirection")
        interaction = payload.get("interaction")
        if (
            isinstance(direction, int)
            and last_direction is not None
            and direction != last_direction
            and interaction in ACTIVE
        ):
            flips.append(policy)
        if isinstance(direction, int):
            last_direction = direction

    resident_timings = [
        event
        for event in timings
        if (event.get("payload") or {}).get("platformResidentReuse") is True
        and int((event.get("payload") or {}).get("durationMicros") or 0) <= 0
    ]

    counts: list[int] = []
    present_micros: list[int] = []
    flip_pages: list[int] = []
    associated_ids: set[int] = set()
    for flip in flips:
        t = int(flip.get("t") or 0)
        page = (flip.get("payload") or {}).get("currentIndex")
        if isinstance(page, int):
            flip_pages.append(page)
        nearby = [
            event
            for event in resident_timings
            if 0 <= int(event.get("t") or 0) - t <= WINDOW_US
        ]
        counts.append(len(nearby))
        present_micros.append(
            sum(int((event.get("payload") or {}).get("presentMicros") or 0) for event in nearby)
        )
        associated_ids.update(id(event) for event in nearby)

    page_counts: dict[int, int] = {}
    for page in flip_pages:
        page_counts[page] = page_counts.get(page, 0) + 1
    page_text = ",".join(
        f"{page}:{count}"
        for page, count in sorted(page_counts.items(), key=lambda item: (-item[1], item[0]))
    ) or "none"

    exactly_two = sum(1 for count in counts if count == 2)
    print(
        f"events={len(events)} active_direction_flips={len(flips)} task_failed={len(task_failures)}"
    )
    print(
        "resident_static_represent="
        f"total={len(resident_timings)} associated={len(associated_ids)} "
        f"flip_exactly_two={exactly_two}/{len(flips)} "
        f"per_flip_median={median(counts)}"
    )
    print(
        "resident_static_present_cost="
        f"per_flip_median_us={median(present_micros)} "
        f"per_flip_max_us={max(present_micros) if present_micros else 0} "
        "window_us=15000 budget_120hz_us=8333"
    )
    print(f"flip_pages={page_text}")
    if task_failures:
        print("verdict=invalid-run-task-failures")
    elif flips and exactly_two == len(flips):
        print("verdict=direction-flip-resident-static-representation")
    elif flips and associated_ids:
        print("verdict=mixed-resident-static-representation")
    elif flips:
        print("verdict=no-resident-static-representation-near-flips")
    else:
        print("verdict=no-active-direction-flip-evidence")


if __name__ == "__main__":
    main()
