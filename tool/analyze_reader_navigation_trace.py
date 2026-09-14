#!/usr/bin/env python3
"""Summarize committed Reader page gestures from a ZIC debug trace.

This analyzer intentionally keys off Reader trace facts instead of Android
accessibility state. Reader overlays may leave Home semantics in the UI tree,
so UI-node presence is not a reliable Reader lifecycle signal.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def _time_us(event: dict[str, Any]) -> int:
    value = event.get("t", event.get("monotonicMicros", 0))
    return int(value) if isinstance(value, (int, float)) else 0


def _page_index(event: dict[str, Any]) -> int | None:
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return None
    value = payload.get("pageIndex")
    return int(value) if isinstance(value, (int, float)) else None


def _read_trace(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {error}")
            if isinstance(event, dict):
                events.append(event)
    events.sort(key=_time_us)
    return events


def _matching_policy(
    events: list[dict[str, Any]],
    *,
    session_id: str,
    current: int,
    target: int,
    started_us: int,
    committed_us: int,
) -> dict[str, Any] | None:
    for event in events:
        event_us = _time_us(event)
        if event_us < started_us:
            continue
        if event_us > committed_us:
            break
        if event.get("sessionId") != session_id or event.get("kind") != "policyDecision":
            continue
        payload = event.get("payload")
        if not isinstance(payload, dict):
            continue
        if payload.get("currentIndex") == current and payload.get("targetIndex") == target:
            return event
    return None


def _matching_mount_and_first_frame(
    events: list[dict[str, Any]],
    *,
    session_id: str,
    target: int,
    started_us: int,
    committed_us: int,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    mount: dict[str, Any] | None = None
    first_frame: dict[str, Any] | None = None
    search_end = committed_us + 1_500_000
    for event in events:
        event_us = _time_us(event)
        if event_us < started_us - 1_000_000:
            continue
        if event_us > search_end:
            break
        if event.get("sessionId") != session_id or _page_index(event) != target:
            continue
        kind = event.get("kind")
        if kind == "pageHostMounted" and mount is None:
            mount = event
        elif kind == "firstFrameReady":
            if mount is None or event_us >= _time_us(mount):
                first_frame = event
                break
    return mount, first_frame


def _matching_prewarm(
    events: list[dict[str, Any]],
    *,
    session_id: str,
    target: int,
    started_us: int,
    first_frame_us: int | None,
) -> dict[str, Any] | None:
    end_us = first_frame_us if first_frame_us is not None else started_us + 1_500_000
    candidate: dict[str, Any] | None = None
    for event in events:
        event_us = _time_us(event)
        if event_us < started_us - 2_000_000:
            continue
        if event_us > end_us:
            break
        if event.get("sessionId") != session_id:
            continue
        if event.get("kind") != "pageOutputPrewarmed" or _page_index(event) != target:
            continue
        candidate = event
    return candidate


def analyze(
    events: list[dict[str, Any]],
    session_filter: str | None,
) -> list[dict[str, Any]]:
    commits: list[dict[str, Any]] = []
    sessions = {
        str(event.get("sessionId"))
        for event in events
        if event.get("kind") == "pageCurrent" and event.get("sessionId") is not None
    }
    if session_filter is not None:
        sessions &= {session_filter}

    for session_id in sorted(sessions):
        session_events = [event for event in events if event.get("sessionId") == session_id]
        previous_commit_us = 0
        for commit in session_events:
            if commit.get("kind") != "pageCurrent":
                continue
            target = _page_index(commit)
            if target is None:
                continue
            committed_us = _time_us(commit)
            transitions: list[dict[str, Any]] = []
            for event in session_events:
                event_us = _time_us(event)
                if event_us <= previous_commit_us or event_us > committed_us:
                    continue
                if event.get("kind") != "pageTransition":
                    continue
                payload = event.get("payload")
                if not isinstance(payload, dict):
                    continue
                if payload.get("targetIndex") != target:
                    continue
                current = payload.get("currentIndex")
                if not isinstance(current, int) or current == target:
                    continue
                transitions.append(event)
            previous_commit_us = committed_us
            if not transitions:
                continue
            dragging = [
                event
                for event in transitions
                if isinstance(event.get("payload"), dict)
                and event["payload"].get("interaction") == "dragging"
            ]
            # A completed PageView settle can briefly emit a dragging-shaped
            # bounce toward the old page. The committed gesture is the last
            # matching drag before pageCurrent, not the first transition in
            # the whole inter-commit interval (which may include exit/re-entry).
            transition = (dragging or transitions)[-1]
            payload = transition["payload"]
            current = int(payload["currentIndex"])
            started_us = _time_us(transition)
            move_sign = 1 if target > current else -1

            policy = _matching_policy(
                session_events,
                session_id=session_id,
                current=current,
                target=target,
                started_us=started_us,
                committed_us=committed_us,
            )
            policy_payload = policy.get("payload") if policy is not None else None
            read_direction = (
                policy_payload.get("readDirection")
                if isinstance(policy_payload, dict)
                else None
            )
            role_at_start = None
            if read_direction in (-1, 1):
                role_at_start = "next" if move_sign == read_direction else "previous"

            mount, first_frame = _matching_mount_and_first_frame(
                session_events,
                session_id=session_id,
                target=target,
                started_us=started_us,
                committed_us=committed_us,
            )
            first_frame_payload = first_frame.get("payload") if first_frame else None
            mount_to_first = (
                first_frame_payload.get("mountToFirstFrameMicros")
                if isinstance(first_frame_payload, dict)
                else None
            )
            first_frame_us = _time_us(first_frame) if first_frame else None
            prewarm = _matching_prewarm(
                session_events,
                session_id=session_id,
                target=target,
                started_us=started_us,
                first_frame_us=first_frame_us,
            )
            prewarm_payload = prewarm.get("payload") if prewarm else None
            prewarm_role = (
                prewarm_payload.get("role") if isinstance(prewarm_payload, dict) else None
            )
            commits.append(
                {
                    "sessionId": session_id,
                    "currentIndex": current,
                    "targetIndex": target,
                    "moveSign": move_sign,
                    "readDirectionAtStart": read_direction,
                    "roleAtStart": role_at_start,
                    "transitionUs": started_us,
                    "commitUs": committed_us,
                    "gestureToCommitMicros": committed_us - started_us,
                    "mounted": mount is not None,
                    "firstFrameReady": first_frame is not None,
                    "mountToFirstFrameMicros": mount_to_first,
                    "prewarmRole": prewarm_role,
                    "prewarmToFirstFrameMicros": (
                        first_frame_us - _time_us(prewarm)
                        if first_frame is not None and prewarm is not None
                        else None
                    ),
                }
            )
    return commits


def _print_text(rows: list[dict[str, Any]]) -> None:
    if not rows:
        print("No committed Reader page gestures found.")
        return
    print(
        "session current->target startRole readDir mount->first(ms) "
        "gesture->commit(ms) prewarm"
    )
    for row in rows:
        mount_us = row["mountToFirstFrameMicros"]
        gesture_us = row["gestureToCommitMicros"]
        mount_ms = "-" if mount_us is None else f"{mount_us / 1000:.1f}"
        gesture_ms = "-" if gesture_us is None else f"{gesture_us / 1000:.1f}"
        print(
            f"{row['sessionId']} {row['currentIndex']}->{row['targetIndex']} "
            f"{row['roleAtStart'] or '-'} {row['readDirectionAtStart']} "
            f"{mount_ms} {gesture_ms} {row['prewarmRole'] or '-'}"
        )

    previous_rows = [row for row in rows if row["roleAtStart"] == "previous"]
    if previous_rows:
        latencies = [
            row["mountToFirstFrameMicros"]
            for row in previous_rows
            if isinstance(row["mountToFirstFrameMicros"], (int, float))
        ]
        summary = f"previous-role committed gestures: {len(previous_rows)}"
        if latencies:
            summary += ", mount->first(ms)=" + "/".join(
                f"{value / 1000:.1f}" for value in latencies
            )
        print(summary)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Summarize committed Reader navigation and stable-direction mismatch windows."
    )
    parser.add_argument("trace", type=Path)
    parser.add_argument("--session", help="limit output to one pipeline-reader session")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()

    rows = analyze(_read_trace(args.trace), args.session)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        _print_text(rows)


if __name__ == "__main__":
    main()
