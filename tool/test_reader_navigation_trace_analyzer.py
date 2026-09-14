#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "tool/analyze_reader_navigation_trace.py"


def event(t: int, kind: str, payload: dict[str, object]) -> dict[str, object]:
    return {
        "t": t,
        "sessionId": "pipeline-reader-test",
        "kind": kind,
        "payload": payload,
    }


with tempfile.TemporaryDirectory(prefix="zic-reader-navigation-") as directory:
    trace = Path(directory) / "trace.jsonl"
    events = [
        event(1, "pageCurrent", {"pageIndex": 10}),
        event(
            10,
            "pageTransition",
            {
                "currentIndex": 10,
                "targetIndex": 11,
                "interaction": "dragging",
            },
        ),
        event(
            11,
            "policyDecision",
            {
                "currentIndex": 10,
                "targetIndex": 11,
                "readDirection": 1,
            },
        ),
        event(12, "pageHostMounted", {"pageIndex": 11}),
        event(13, "pageOutputPrewarmed", {"pageIndex": 11, "role": "next"}),
        event(
            14,
            "firstFrameReady",
            {"pageIndex": 11, "mountToFirstFrameMicros": 2000},
        ),
        event(20, "pageCurrent", {"pageIndex": 11}),
        # PageView may briefly bounce toward the old page after a completed
        # settle. The analyzer must not mistake this for the later real reverse
        # gesture after exit/re-entry.
        event(
            21,
            "pageTransition",
            {
                "currentIndex": 11,
                "targetIndex": 10,
                "interaction": "dragging",
            },
        ),
        event(
            100,
            "pageTransition",
            {
                "currentIndex": 11,
                "targetIndex": 10,
                "interaction": "dragging",
            },
        ),
        event(
            101,
            "policyDecision",
            {
                "currentIndex": 11,
                "targetIndex": 10,
                "readDirection": 1,
            },
        ),
        event(102, "pageHostMounted", {"pageIndex": 10}),
        event(
            103,
            "pageOutputPrewarmed",
            {"pageIndex": 10, "role": "transition"},
        ),
        event(
            104,
            "firstFrameReady",
            {"pageIndex": 10, "mountToFirstFrameMicros": 32000},
        ),
        event(130, "pageCurrent", {"pageIndex": 10}),
        event(
            200,
            "pageTransition",
            {
                "currentIndex": 10,
                "targetIndex": 9,
                "interaction": "dragging",
            },
        ),
        event(
            201,
            "policyDecision",
            {
                "currentIndex": 10,
                "targetIndex": 9,
                "readDirection": -1,
            },
        ),
        event(202, "pageHostMounted", {"pageIndex": 9}),
        event(
            204,
            "firstFrameReady",
            {"pageIndex": 9, "mountToFirstFrameMicros": 44000},
        ),
        event(230, "pageCurrent", {"pageIndex": 9}),
    ]
    trace.write_text(
        "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in events),
        encoding="utf-8",
    )

    completed = subprocess.run(
        ["python3", str(ANALYZER), str(trace), "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = json.loads(completed.stdout)

assert len(rows) == 3, rows
assert rows[0]["roleAtStart"] == "next", rows[0]
assert rows[0]["mountToFirstFrameMicros"] == 2000, rows[0]
assert rows[1]["roleAtStart"] == "previous", rows[1]
assert rows[1]["readDirectionAtStart"] == 1, rows[1]
assert rows[1]["transitionUs"] == 100, rows[1]
assert rows[1]["gestureToCommitMicros"] == 30, rows[1]
assert rows[1]["mountToFirstFrameMicros"] == 32000, rows[1]
assert rows[1]["prewarmRole"] == "transition", rows[1]
assert rows[2]["roleAtStart"] == "next", rows[2]
assert rows[2]["readDirectionAtStart"] == -1, rows[2]
print("reader navigation trace analyzer: OK")
