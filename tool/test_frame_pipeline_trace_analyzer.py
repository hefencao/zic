#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "tool/analyze_frame_pipeline_trace.py"

with tempfile.TemporaryDirectory(prefix="zic-frame-trace-") as directory:
    trace = Path(directory) / "trace.jsonl"
    events = [
        {
            "t": 10,
            "sessionId": "upload-a",
            "kind": "framePipelineTiming",
            "payload": {
                "frame": 0,
                "cycle": 0,
                "presentationOrdinal": 0,
                "traceReason": "startup+stall",
                "dominantStage": "workerReady",
                "dominantStageMicros": 300000,
                "workerReadyMicros": 300000,
                "platformOtherMicros": 12000,
                "endToEndMicros": 410000,
                "presentMicros": 50000,
                "presentationPath": "platform",
            },
        },
        {
            "t": 11,
            "sessionId": "noise",
            "kind": "framePresented",
            "payload": {"frame": 0},
        },
        {
            "t": 20,
            "sessionId": "upload-a",
            "kind": "framePipelineTiming",
            "payload": {
                "frame": 1,
                "cycle": 0,
                "presentationOrdinal": 1,
                "traceReason": "startup",
                "dominantStage": "nativeDecode",
                "dominantStageMicros": 90000,
                "nativeDecodeMicros": 90000,
                "endToEndMicros": 120000,
                "presentMicros": 20000,
                "presentationPath": "platform",
            },
        },
        {
            "t": 21,
            "sessionId": "reader-a",
            "kind": "sourceRead",
            "payload": {
                "source": "artifact-cache-stream",
                "sourceClass": "persistent-artifact",
                "consumer": "session-copy",
                "bytes": 1048576,
                "chunks": 1,
                "firstChunkMicros": 2000,
                "streamMicros": 3000,
                "maxChunkGapMicros": 2000,
                "maxChunkBytes": 1048576,
                "completed": True,
            },
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "taskFailed",
            "payload": {
                "lane": "decode",
                "role": "current",
                "laneQueueMicros": 4000,
                "executionMicros": 5000,
                "taskElapsedMicros": 9000,
                "error": "decode failed",
            },
        },
    ]
    trace.write_text(
        "".join(json.dumps(event) + "\n" for event in events),
        encoding="utf-8",
    )
    output = subprocess.check_output(
        ["python3", str(ANALYZER), str(trace), "--json"],
        text=True,
    )
    report = json.loads(output)

assert report["eventCount"] == 2
assert report["reasonCounts"] == {"startup+stall": 1, "startup": 1}
assert report["dominantStageCounts"] == {"workerReady": 1, "nativeDecode": 1}
assert report["endToEndMicros"]["p50"] == 120000
assert report["endToEndMicros"]["max"] == 410000
assert report["stages"]["workerReadyMicros"]["max"] == 300000
assert report["stages"]["platformOtherMicros"]["max"] == 12000
assert report["sourceReadCount"] == 1
assert report["sourceReadMicros"]["max"] == 3000
assert report["taskFailureCount"] == 1
assert report["taskFailures"][0]["executionMicros"] == 5000
assert report["frames"][0]["frame"] == 0
print("frame pipeline trace analyzer: OK")
