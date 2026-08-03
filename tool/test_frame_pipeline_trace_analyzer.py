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
                "decodedAtMicros": 600000,
                "uploadStartedAtMicros": 640000,
                "decodedToUploadMicros": 40000,
                "platformOtherMicros": 12000,
                "platformScheduleMicros": 110000,
                "platformScheduleQueueMicros": 100000,
                "platformScheduleCallMicros": 10000,
                "presentedAtMicros": 1000000,
                "durationMicros": 100000,
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
                "dominantStage": "decodedToUpload",
                "dominantStageMicros": 950000,
                "decodedAtMicros": 200000,
                "uploadStartedAtMicros": 1150000,
                "decodedRole": "next",
                "uploadRole": "current",
                "decodedToUploadMicros": 950000,
                "nativeDecodeMicros": 90000,
                "presentedAtMicros": 1200000,
                "durationMicros": 100000,
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
                "source": "artifact-read-all",
                "sourceClass": "persistent-artifact",
                "consumer": "session-copy",
                "artifactReadMode": "read-all",
                "memoryCacheHit": False,
                "memoryCacheJoined": False,
                "artifactMaterializeMicros": 1500,
                "hotCacheEntries": 1,
                "hotCacheBytes": 1048576,
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
assert report["recordedDominantStageCounts"] == {
    "workerReady": 1,
    "decodedToUpload": 1,
}
assert report["dominantStageCounts"] == {"workerReady": 1, "nativeDecode": 1}
assert report["endToEndMicros"]["p50"] == 120000
assert report["endToEndMicros"]["max"] == 410000
assert report["stages"]["workerReadyMicros"]["max"] == 300000
assert report["stages"]["platformOtherMicros"]["max"] == 12000
assert report["stages"]["platformScheduleQueueMicros"]["max"] == 100000
assert report["stages"]["platformScheduleCallMicros"]["max"] == 10000
assert report["stages"]["decodedLeadMicros"]["max"] == 950000
assert report["stages"]["uploadBackpressureMicros"]["max"] == 40000
assert report["sourceReadCount"] == 1
assert report["processClock"] is False
assert report["sourceConcurrencyScope"] == "per-session-legacy-clock"
assert report["sourceReadMicros"]["max"] == 3000
assert report["sourceReadModeCounts"] == {"read-all": 1}
assert report["sourceMemoryCacheHits"] == 0
assert report["sourceMemoryCacheJoins"] == 0
assert report["sourceArtifactMaterializeMicros"]["max"] == 1500
assert report["sourceReads"][0]["hotCacheEntries"] == 1
assert report["taskFailureCount"] == 1
assert report["taskFailures"][0]["executionMicros"] == 5000
assert report["frames"][0]["frame"] == 0
assert report["frames"][1]["recordedDominantStage"] == "decodedToUpload"
assert report["frames"][1]["dominantStage"] == "nativeDecode"
print("frame pipeline trace analyzer: OK")
