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
                "startupFrameOrdinal": 0,
                "traceReason": "startup+stall",
                "dominantStage": "workerReady",
                "dominantStageMicros": 300000,
                "workerReadyMicros": 300000,
                "decodedAtMicros": 600000,
                "uploadStartedAtMicros": 640000,
                "decodedToUploadMicros": 40000,
                "platformOtherMicros": 12000,
                "platformConfigureMicros": 15000,
                "blitRetryCount": 1,
                "surfaceReconfigureCount": 1,
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
                "deliveryMode": "whole-body",
                "memoryCacheHit": False,
                "memoryCacheJoined": False,
                "artifactMaterializeMicros": 1500,
                "hotCacheEntries": 1,
                "hotCacheBytes": 1048576,
                "readSchedulerPressureHolds": 1,
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
            "t": 5,
            "sessionId": "reader-a",
            "kind": "readerSessionCreated",
            "payload": {},
        },
        {
            "t": 23,
            "sessionId": "reader-a",
            "kind": "artifactSource",
            "identityHash": "artifact-a",
            "payload": {
                "source": "session-artifact-handoff",
                "consumer": "persistent-cache",
                "action": "skip-existing",
                "bytes": 1048576,
                "handoffMicros": 700,
            },
        },
        {
            "t": 24,
            "sessionId": "reader-a",
            "kind": "readerSessionDisposeStarted",
            "payload": {},
        },
        {
            "t": 30,
            "sessionId": "reader-a",
            "kind": "readerSessionDisposed",
            "payload": {
                "disposeMicros": 6000,
                "coordinatorDisposeMicros": 1000,
                "handoffDrainMicros": 700,
                "mediaCloseMicros": 800,
                "downloadsDisposeMicros": 900,
                "workspaceDisposeMicros": 1000,
            },
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "decodeRefill",
            "identityHash": "decode-current",
            "payload": {
                "role": "current",
                "stage": "c>3",
                "depth": 2,
                "threshold": 3,
                "target": 4,
                "sourceWake": True,
                "sourceRevision": 3,
                "consumedSourceRevision": 2,
            },
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "retryScheduled",
            "identityHash": "decode-current",
            "payload": {
                "stage": "decode-recovery",
                "attempt": 1,
                "delayUs": 16000,
                "role": "current",
                "bufferedDepth": 7,
            },
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "retryScheduled",
            "identityHash": "decode-current",
            "payload": {
                "stage": "decode-prefix",
                "frame": 2,
                "sourceLength": 300000,
                "nextSourceLength": 524288,
            },
        },
        {
            "t": 6,
            "sessionId": "reader-a",
            "kind": "downloadStarted",
            "identityHash": "download-local-current",
            "payload": {
                "priority": 1000,
                "bucket": "local",
                "bucketLimit": 1,
                "globalActive": 1,
                "globalLimit": 5,
                "handoffActive": 0,
                "effectivePriority": 1000,
                "bucketActive": 1,
            },
        },
        {
            "t": 15,
            "sessionId": "reader-a",
            "kind": "frameUploaded",
            "identityHash": "decode-current",
            "payload": {
                "frame": 0,
                "textureLeaseReused": True,
                "uploadMicros": 1200,
                "surfaceReconfigureCount": 0,
            },
        },
        {
            "t": 16,
            "sessionId": "reader-a",
            "kind": "firstFrameReady",
            "identityHash": "page-current",
            "payload": {
                "pageIndex": 0,
                "mountToFirstFrameMicros": 390000,
            },
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "downloadStarted",
            "identityHash": "download-current",
            "payload": {
                "priority": 1000,
                "bucket": "remote:source",
                "bucketLimit": 5,
                "globalActive": 3,
                "globalLimit": 5,
                "bucketActive": 2,
            },
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "downloadPriorityChanged",
            "identityHash": "download-current",
            "payload": {
                "oldPriority": 820,
                "newPriority": 1000,
                "active": True,
            },
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "lastFrameKept",
            "identityHash": "decode-last",
            "payload": {"frame": 7, "outputBytes": 4300800},
        },
        {
            "t": 23,
            "sessionId": "reader-a",
            "kind": "staticFrameKept",
            "identityHash": "decode-static",
            "payload": {"frame": 0, "outputBytes": 7271680},
        },
        {
            "t": 22,
            "sessionId": "reader-a",
            "kind": "mediaClassified",
            "identityHash": "download-static-webp",
            "payload": {
                "pageIndex": 4,
                "animated": False,
                "frameCount": 1,
                "loopCount": 1,
                "complete": True,
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
                "error": "Failure(decode): frame decode failed",
                "sourceLength": 1048576,
                "sourceSealed": False,
                "requiredSourceLength": 2097152,
                "failureClass": "partial-source",
            },
        },
            {
            "t": 700,
            "sessionId": "reader-resume",
            "kind": "frameUploaded",
            "identityHash": "decode-retained",
            "revision": 1,
            "payload": {
                "frame": 7,
                "restored": True,
                "restoreSource": "texture-pool",
                "outputBytes": 4096,
                "width": 32,
                "height": 32,
            },
        },
        {
            "t": 705,
            "sessionId": "upload-a",
            "kind": "playbackBuffering",
            "identityHash": "decode-current",
            "payload": {
                "state": "waiting",
                "frame": 0,
                "successorDepth": 2,
                "targetDepth": 7,
                "durationMicros": 33333,
            },
        },
        {
            "t": 706,
            "sessionId": "upload-a",
            "kind": "playbackBuffering",
            "identityHash": "decode-current",
            "payload": {
                "state": "ready",
                "frame": 0,
                "successorDepth": 7,
                "targetDepth": 7,
                "durationMicros": 33333,
            },
        },
        {
            "t": 710,
            "sessionId": "reader-resume",
            "kind": "retryScheduled",
            "identityHash": "decode-partial",
            "revision": 1,
            "payload": {
                "stage": "decode-source-growth",
                "role": "current",
                "sourceLength": 1048576,
                "requiredSourceLength": 2097152,
                "waitForSourceRevision": True,
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
assert report["stages"]["platformConfigureMicros"]["max"] == 15000
assert report["stages"]["platformScheduleQueueMicros"]["max"] == 100000
assert report["stages"]["platformScheduleCallMicros"]["max"] == 10000
assert report["stages"]["decodedLeadMicros"]["max"] == 950000
assert report["stages"]["uploadBackpressureMicros"]["max"] == 40000
assert report["sourceReadCount"] == 1
assert report["processClock"] is True
assert report["sourceConcurrencyScope"] == "process"
assert report["sourceReadMicros"]["max"] == 3000
assert report["sourceReadModeCounts"] == {"read-all": 1}
assert report["sourceDeliveryModeCounts"] == {"whole-body": 1}
assert report["sourceReadSchedulerPressureHolds"]["max"] == 1
assert report["sourceMemoryCacheHits"] == 0
assert report["sourceMemoryCacheJoins"] == 0
assert report["sourceArtifactMaterializeMicros"]["max"] == 1500
assert report["emptyArtifactEventCount"] == 0
assert report["emptyArtifactHandoffStoreCount"] == 0
assert report["cacheResidentCommitCount"] == 0
assert report["textureLeasePresentationCount"] == 1
assert report["sourceReads"][0]["hotCacheEntries"] == 1

assert report["firstFrameReadyCount"] == 1
assert report["mountToFirstFrameMicros"]["max"] == 390000
assert report["startupLocalDownloadMaxBucketActive"] == 1
assert report["startupLocalDownloadBucketLimits"] == [1]
assert report["startupFirstTextureLeaseReuseCount"] == 1
assert report["startupFirstSurfaceReconfigureCount"] == 1

assert report["readerSessionLifecycle"]["reader-a"]["disposeMicros"] == 6000
assert report["readerSessionLifecycle"]["reader-a"]["handoffDrainMicros"] == 700
assert report["cacheHandoffActionCounts"] == {"skip-existing": 1}
assert report["cacheHandoffMicros"]["max"] == 700
assert report["cacheHandoffs"][0]["bytes"] == 1048576
assert report["decodeRefillCount"] == 1
assert report["decodeRefillRoleCounts"] == {"current": 1}
assert report["decodeRefillStageCounts"] == {"c>3": 1}
assert report["decodeRefillSourceWakeCount"] == 1
assert report["decodeRefills"][0]["target"] == 4
assert report["decodeRefills"][0]["sourceRevision"] == 3
assert report["decodeRecoveryCount"] == 1
assert report["decodeRecoveryAttemptCounts"] == {"1": 1}
assert report["decodeRecoveries"][0]["bufferedDepth"] == 7
assert report["decodePrefixHintCount"] == 1
assert report["decodePrefixHints"][0]["nextSourceLength"] == 524288
assert report["playbackBufferingCount"] == 2
assert report["playbackBufferingReadyCount"] == 1
assert report["playbackBufferingCompletedCount"] == 1
assert report["playbackBufferingWaitMicros"]["max"] == 1
assert report["playbackBufferingOutstandingCount"] == 0
assert report["playbackBuffering"][0]["targetDepth"] == 7
assert report["playbackBuffering"][1]["state"] == "ready"
assert report["rankedDownloadCount"] == 2
assert report["rankedDownloadMaxGlobalActive"] == 3
assert report["rankedDownloadMaxHandoffActive"] == 0
assert report["rankedDownloadPriorityMigrationCount"] == 1
assert report["rankedDownloadActivePriorityMigrationCount"] == 1
assert report["downloadPriorityChanges"][0]["newPriority"] == 1000
assert report["rankedDownloadBucketCounts"] == {"local": 1, "remote:source": 1}
assert report["mediaClassificationCount"] == 1
assert report["runtimeStaticClassificationCount"] == 1
assert report["runtimeAnimatedClassificationCount"] == 0
assert report["mediaClassifications"][0]["pageIndex"] == 4
assert report["lastFrameKeptCount"] == 1
assert report["lastFramesKept"][0]["frame"] == 7
assert report["staticFrameKeptCount"] == 1
assert report["staticFramesKept"][0]["outputBytes"] == 7271680
assert report["taskFailureCount"] == 1
assert report["blitLockFailureCount"] == 0
assert report["blitFallbackCount"] == 0
assert report["taskFailures"][0]["failureClass"] == "partial-source"
assert report["taskFailures"][0]["requiredSourceLength"] == 2097152
assert report["platformConfigureMicros"]["max"] == 15000
assert report["blitRetryCount"] == 1
assert report["surfaceReconfigureCount"] == 1
assert report["taskFailures"][0]["executionMicros"] == 5000
assert report["frames"][0]["frame"] == 0
assert report["frames"][1]["recordedDominantStage"] == "decodedToUpload"
assert report["frames"][1]["dominantStage"] == "nativeDecode"
print("frame pipeline trace analyzer: OK")
