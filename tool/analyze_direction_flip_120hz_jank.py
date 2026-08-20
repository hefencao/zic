#!/usr/bin/env python3
"""Summarize active read-direction flip demand churn near a 120 Hz budget."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

ACTIVE = {"dragging", "scrolling", "settling"}


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
    fixed_list_failures = [
        event
        for event in task_failures
        if "Cannot remove from a fixed-length list"
        in str((event.get("payload") or {}).get("error") or "")
    ]

    reconciles = {
        event.get("revision"): event
        for event in events
        if event.get("kind") == "pipelineReconcileTiming"
        and isinstance(event.get("revision"), int)
    }
    policies = [event for event in events if event.get("kind") == "policyDecision"]

    last_direction: int | None = None
    flips: list[tuple[dict, dict | None]] = []
    bridge_events = 0
    bridge_retained = 0
    bridge_deferred = 0
    for policy in policies:
        payload = policy.get("payload") or {}
        direction = payload.get("readDirection")
        interaction = payload.get("interaction")
        if payload.get("downloadBridgeActive") is True:
            bridge_events += 1
            bridge_retained += int(payload.get("downloadBridgeRetained") or 0)
            bridge_deferred += int(payload.get("downloadBridgeDeferredDesired") or 0)
        if (
            isinstance(direction, int)
            and last_direction is not None
            and direction != last_direction
            and interaction in ACTIVE
        ):
            flips.append((policy, reconciles.get(policy.get("revision"))))
        if isinstance(direction, int):
            last_direction = direction

    flip_reconcile_us: list[int] = []
    big_5x5 = 0
    membership_adds: list[int] = []
    membership_removes: list[int] = []
    changed: list[int] = []
    flip_pages: list[int] = []
    for policy, reconcile in flips:
        page = (policy.get("payload") or {}).get("currentIndex")
        if isinstance(page, int):
            flip_pages.append(page)
        if reconcile is None:
            continue
        payload = reconcile.get("payload") or {}
        micros = payload.get("reconcileMicros")
        if isinstance(micros, int):
            flip_reconcile_us.append(micros)
        added = int(payload.get("downloadAdded") or 0)
        removed = int(payload.get("downloadRemoved") or 0)
        chg = int(payload.get("downloadChanged") or 0)
        membership_adds.append(added)
        membership_removes.append(removed)
        changed.append(chg)
        if added >= 5 and removed >= 5:
            big_5x5 += 1

    page_counts: dict[int, int] = {}
    for page in flip_pages:
        page_counts[page] = page_counts.get(page, 0) + 1
    page_text = ",".join(
        f"{page}:{count}"
        for page, count in sorted(page_counts.items(), key=lambda item: (-item[1], item[0]))
    ) or "none"

    print(
        f"events={len(events)} policies={len(policies)} active_direction_flips={len(flips)} "
        f"task_failed={len(task_failures)} fixed_list_failures={len(fixed_list_failures)}"
    )
    print(
        "flip_download_churn="
        f"big_5x5={big_5x5} "
        f"added_median={median(membership_adds)} "
        f"removed_median={median(membership_removes)} "
        f"changed_median={median(changed)}"
    )
    print(
        "flip_reconcile="
        f"count={len(flip_reconcile_us)} median_us={median(flip_reconcile_us)} "
        f"max_us={max(flip_reconcile_us) if flip_reconcile_us else 0} "
        "budget_120hz_us=8333"
    )
    print(f"flip_pages={page_text}")
    print(
        "download_bridge="
        f"events={bridge_events} retained_total={bridge_retained} "
        f"deferred_desired_total={bridge_deferred}"
    )
    if fixed_list_failures:
        print("verdict=invalid-bridge-run-fixed-length-mutation-failure")
    elif task_failures:
        print("verdict=invalid-run-task-failures")
    elif flips and big_5x5 == len(flips):
        print("verdict=active-direction-flip-full-window-churn")
    elif flips and bridge_events and big_5x5 == 0:
        print("verdict=active-download-bridge-observed-without-full-window-flips")
    elif flips:
        print("verdict=mixed-direction-flip-churn")
    else:
        print("verdict=no-active-direction-flip-evidence")


if __name__ == "__main__":
    main()
