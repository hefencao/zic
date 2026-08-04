#!/usr/bin/env python3
"""Summarize frame-pipeline, ingress, and failure timing from a ZIC trace."""

from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

STAGE_FIELDS = (
    "workerReadyMicros",
    "decodeLaneQueueMicros",
    "sourceWaitMicros",
    "cursorCreateMicros",
    "workerQueueMicros",
    "decodeDispatchMicros",
    "nativeDecodeMicros",
    "nativeMetadataMicros",
    "decodedToUploadMicros",
    "decodedLeadMicros",
    "uploadBackpressureMicros",
    "uploadLaneQueueMicros",
    "outputPrepareMicros",
    "outputReadyToPresentMicros",
    "platformQueueMicros",
    "platformUploadMicros",
    "platformOtherMicros",
    "platformRetainMicros",
    "platformConfigureMicros",
    "platformBlitMicros",
    "platformScheduleMicros",
    "platformScheduleQueueMicros",
    "platformScheduleCallMicros",
    "platformScheduleLegacyMicros",
    "platformReplaceMicros",
    "platformResultDispatchMicros",
    "channelDispatchMicros",
    "fallbackDecodeMicros",
)

# These fields are mutually attributable enough to select a useful bottleneck.
# decodedLead is intentional successor work, decodedToUpload contains that lead,
# and platformUpload overlaps the platform sub-stages, so none of those three
# participates directly in dominant-stage selection.
DOMINANT_STAGE_FIELDS = {
    "workerReady": "workerReadyMicros",
    "decodeLaneQueue": "decodeLaneQueueMicros",
    "sourceWait": "sourceWaitMicros",
    "cursorCreate": "cursorCreateMicros",
    "workerQueue": "workerQueueMicros",
    "decodeDispatch": "decodeDispatchMicros",
    "nativeDecode": "nativeDecodeMicros",
    "nativeMetadata": "nativeMetadataMicros",
    "uploadBackpressure": "uploadBackpressureMicros",
    "uploadLaneQueue": "uploadLaneQueueMicros",
    "outputPrepare": "outputPrepareMicros",
    "outputReadyToPresent": "outputReadyToPresentMicros",
    "platformQueue": "platformQueueMicros",
    "platformOther": "platformOtherMicros",
    "platformRetain": "platformRetainMicros",
    "platformConfigure": "platformConfigureMicros",
    "platformBlit": "platformBlitMicros",
    "platformScheduleQueue": "platformScheduleQueueMicros",
    "platformScheduleCall": "platformScheduleCallMicros",
    "platformScheduleLegacy": "platformScheduleLegacyMicros",
    "platformReplace": "platformReplaceMicros",
    "platformResultDispatch": "platformResultDispatchMicros",
    "channelDispatch": "channelDispatchMicros",
    "fallbackDecode": "fallbackDecodeMicros",
}


def _number(value: Any) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def _percentile(values: list[int], fraction: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1))
    return ordered[index]


def _stats(values: list[int]) -> dict[str, int]:
    return {
        "p50": _percentile(values, 0.50),
        "p95": _percentile(values, 0.95),
        "max": max(values, default=0),
    }


def _events(path: Path) -> Iterable[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as source:
        for line_number, raw in enumerate(source, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {error}") from error
            if isinstance(event, dict):
                yield event


def _normalized_waits(
    payload: dict[str, Any],
    previous_due_micros: int | None,
) -> tuple[int, int]:
    raw_wait = _number(payload.get("decodedToUploadMicros"))
    decoded_role = str(payload.get("decodedRole", "unknown"))
    upload_role = str(payload.get("uploadRole", "unknown"))
    if (
        raw_wait > 0
        and decoded_role != "unknown"
        and upload_role != "unknown"
        and decoded_role != upload_role
    ):
        return raw_wait, 0
    if "decodedLeadMicros" in payload or "uploadBackpressureMicros" in payload:
        return (
            _number(payload.get("decodedLeadMicros")),
            _number(payload.get("uploadBackpressureMicros")),
        )

    decoded_at = _number(payload.get("decodedAtMicros"))
    upload_started = _number(payload.get("uploadStartedAtMicros"))
    if decoded_at <= 0 or upload_started <= 0:
        return 0, raw_wait
    if previous_due_micros is None:
        return 0, max(0, upload_started - decoded_at)

    lead = max(0, min(raw_wait, previous_due_micros - decoded_at))
    backpressure_start = max(decoded_at, previous_due_micros)
    backpressure = max(0, upload_started - backpressure_start)
    return lead, backpressure


def _dominant(payload: dict[str, Any]) -> tuple[str, int]:
    pairs = (
        (name, _number(payload.get(field)))
        for name, field in DOMINANT_STAGE_FIELDS.items()
    )
    return max(pairs, key=lambda item: item[1], default=("unknown", 0))


def summarize(path: Path) -> dict[str, Any]:
    events = list(_events(path))
    has_process_clock = any(
        event.get("kind") == "readerSessionCreated" for event in events
    )
    dominant = Counter()
    recorded_dominant = Counter()
    reasons = Counter()
    paths = Counter()
    stages: dict[str, list[int]] = defaultdict(list)
    end_to_end: list[int] = []
    present: list[int] = []
    rows: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    source_reads: list[dict[str, Any]] = []
    cache_handoffs: list[dict[str, Any]] = []
    decode_refills: list[dict[str, Any]] = []
    decode_recoveries: list[dict[str, Any]] = []
    decode_prefix_hints: list[dict[str, Any]] = []
    ranked_downloads: list[dict[str, Any]] = []
    last_frames_kept: list[dict[str, Any]] = []
    cache_resident_commits: list[dict[str, Any]] = []
    texture_presentations: list[dict[str, Any]] = []
    next_due_by_session: dict[str, int] = {}
    session_lifecycle: dict[str, dict[str, int]] = defaultdict(dict)

    for event in events:
        kind = event.get("kind")
        payload = event.get("payload")
        if not isinstance(payload, dict):
            payload = {}
        if kind in {
            "readerSessionCreated",
            "readerSessionDisposeStarted",
            "readerSessionDisposed",
        }:
            session_id = str(event.get("sessionId", ""))
            session_lifecycle[session_id][kind] = _number(event.get("t"))
            if kind == "readerSessionDisposed":
                for field in (
                    "disposeMicros",
                    "coordinatorDisposeMicros",
                    "handoffDrainMicros",
                    "mediaCloseMicros",
                    "downloadsDisposeMicros",
                    "workspaceDisposeMicros",
                ):
                    session_lifecycle[session_id][field] = _number(
                        payload.get(field)
                    )
        if kind == "framePipelineTiming":
            session_id = str(event.get("sessionId", ""))
            previous_due = (
                None
                if _number(payload.get("presentationOrdinal")) == 0
                else next_due_by_session.get(session_id)
            )
            lead, backpressure = _normalized_waits(payload, previous_due)
            normalized_payload = dict(payload)
            normalized_payload["decodedLeadMicros"] = lead
            normalized_payload["uploadBackpressureMicros"] = backpressure
            schedule_queue = _number(payload.get("platformScheduleQueueMicros"))
            schedule_call = _number(payload.get("platformScheduleCallMicros"))
            schedule_total = _number(payload.get("platformScheduleMicros"))
            normalized_payload["platformScheduleLegacyMicros"] = (
                schedule_total
                if schedule_total > 0 and schedule_queue == 0 and schedule_call == 0
                else 0
            )
            platform_upload = _number(payload.get("platformUploadMicros"))
            if platform_upload > 0:
                normalized_payload["platformOtherMicros"] = max(
                    0,
                    platform_upload
                    - _number(payload.get("platformRetainMicros"))
                    - _number(payload.get("platformConfigureMicros"))
                    - _number(payload.get("platformBlitMicros"))
                    - _number(payload.get("platformScheduleMicros"))
                    - _number(payload.get("platformReplaceMicros")),
                )
            normalized_stage, normalized_stage_micros = _dominant(normalized_payload)
            recorded_stage = str(payload.get("dominantStage", "unknown"))

            dominant[normalized_stage] += 1
            recorded_dominant[recorded_stage] += 1
            reasons[str(payload.get("traceReason", "unknown"))] += 1
            paths[str(payload.get("presentationPath", "unknown"))] += 1
            for field in STAGE_FIELDS:
                stages[field].append(_number(normalized_payload.get(field)))
            end_to_end.append(_number(payload.get("endToEndMicros")))
            present.append(_number(payload.get("presentMicros")))
            rows.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "frame": payload.get("frame"),
                    "cycle": payload.get("cycle"),
                    "ordinal": payload.get("presentationOrdinal"),
                    "startupFrameOrdinal": payload.get("startupFrameOrdinal"),
                    "role": payload.get("role"),
                    "decodedRole": payload.get("decodedRole"),
                    "uploadRole": payload.get("uploadRole"),
                    "reason": payload.get("traceReason"),
                    "recordedDominantStage": recorded_stage,
                    "dominantStage": normalized_stage,
                    "dominantStageMicros": normalized_stage_micros,
                    "decodedToUploadMicros": _number(
                        payload.get("decodedToUploadMicros")
                    ),
                    "decodedLeadMicros": lead,
                    "uploadBackpressureMicros": backpressure,
                    "endToEndMicros": _number(payload.get("endToEndMicros")),
                    "presentMicros": _number(payload.get("presentMicros")),
                    "deadlineMissMicros": _number(payload.get("deadlineMissMicros")),
                    "presentationPath": payload.get("presentationPath"),
                    "platformConfigureMicros": _number(
                        payload.get("platformConfigureMicros")
                    ),
                    "blitRetryCount": _number(payload.get("blitRetryCount")),
                    "surfaceReconfigureCount": _number(
                        payload.get("surfaceReconfigureCount")
                    ),
                }
            )
            presented_at = _number(payload.get("presentedAtMicros"))
            duration = _number(payload.get("durationMicros"))
            if presented_at > 0 and duration > 0:
                next_due_by_session[session_id] = presented_at + duration
            elif duration <= 0:
                next_due_by_session.pop(session_id, None)
        elif kind == "bytesCommitted" and payload.get("cacheResident") is True:
            cache_resident_commits.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "bytes": _number(payload.get("bytes")),
                    "committedLength": _number(payload.get("committedLength")),
                    "nativeIngressMicros": _number(
                        payload.get("nativeIngressMicros")
                    ),
                    "artifactWriteMicros": _number(
                        payload.get("artifactWriteMicros")
                    ),
                }
            )
        elif kind == "frameUploaded" and "textureLeaseReused" in payload:
            texture_presentations.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "textureLeaseReused": payload.get("textureLeaseReused"),
                    "uploadMicros": _number(payload.get("uploadMicros")),
                }
            )
        elif kind == "taskFailed":
            failures.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "lane": payload.get("lane"),
                    "role": payload.get("role"),
                    "error": payload.get("error") or payload.get("reason"),
                    "fallback": payload.get("fallback"),
                    "blitStatus": (
                        4
                        if "status 4" in str(payload.get("reason") or payload.get("error") or "")
                        else None
                    ),
                    "laneQueueMicros": _number(payload.get("laneQueueMicros")),
                    "executionMicros": _number(payload.get("executionMicros")),
                    "taskElapsedMicros": _number(payload.get("taskElapsedMicros")),
                    "sourceLength": _number(payload.get("sourceLength")),
                    "sourceSealed": payload.get("sourceSealed"),
                    "requiredSourceLength": _number(
                        payload.get("requiredSourceLength")
                    ),
                    "failureClass": payload.get("failureClass"),
                }
            )
        elif kind == "downloadStarted":
            ranked_downloads.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "priority": _number(payload.get("priority")),
                    "bucket": payload.get("bucket"),
                    "bucketLimit": _number(payload.get("bucketLimit")),
                    "globalActive": _number(payload.get("globalActive")),
                    "globalLimit": _number(payload.get("globalLimit")),
                    "bucketActive": _number(payload.get("bucketActive")),
                }
            )
        elif kind == "sourceRead":
            source_reads.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "source": payload.get("source"),
                    "sourceClass": payload.get("sourceClass"),
                    "consumer": payload.get("consumer"),
                    "priority": _number(payload.get("priority")),
                    "artifactReadMode": payload.get("artifactReadMode"),
                    "deliveryMode": payload.get("deliveryMode"),
                    "memoryCacheHit": payload.get("memoryCacheHit"),
                    "memoryCacheJoined": payload.get("memoryCacheJoined"),
                    "artifactMaterializeMicros": _number(
                        payload.get("artifactMaterializeMicros")
                    ),
                    "hotCacheEntries": _number(payload.get("hotCacheEntries")),
                    "hotCacheBytes": _number(payload.get("hotCacheBytes")),
                    "bytes": _number(payload.get("bytes")),
                    "chunks": _number(payload.get("chunks")),
                    "openMicros": _number(payload.get("openMicros")),
                    "readSchedulerWaitMicros": _number(
                        payload.get("readSchedulerWaitMicros")
                    ),
                    "readSchedulerMaxWaitMicros": _number(
                        payload.get("readSchedulerMaxWaitMicros")
                    ),
                    "readSchedulerAcquires": _number(
                        payload.get("readSchedulerAcquires")
                    ),
                    "readSchedulerForegroundAcquires": _number(
                        payload.get("readSchedulerForegroundAcquires")
                    ),
                    "readSchedulerPressureHolds": _number(
                        payload.get("readSchedulerPressureHolds")
                    ),
                    "firstChunkMicros": _number(payload.get("firstChunkMicros")),
                    "streamMicros": _number(payload.get("streamMicros")),
                    "maxChunkGapMicros": _number(payload.get("maxChunkGapMicros")),
                    "maxChunkBytes": _number(payload.get("maxChunkBytes")),
                    "completed": payload.get("completed"),
                }
            )
        elif kind == "retryScheduled" and payload.get("stage") == "decode-recovery":
            decode_recoveries.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "attempt": _number(payload.get("attempt")),
                    "delayUs": _number(payload.get("delayUs")),
                    "role": payload.get("role"),
                    "bufferedDepth": _number(payload.get("bufferedDepth")),
                }
            )
        elif kind == "retryScheduled" and payload.get("stage") == "decode-prefix":
            decode_prefix_hints.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "frame": _number(payload.get("frame")),
                    "sourceLength": _number(payload.get("sourceLength")),
                    "nextSourceLength": _number(payload.get("nextSourceLength")),
                }
            )
        elif kind == "decodeRefill":
            decode_refills.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "role": payload.get("role"),
                    "stage": payload.get("stage"),
                    "depth": _number(payload.get("depth")),
                    "threshold": _number(payload.get("threshold")),
                    "target": _number(payload.get("target")),
                }
            )
        elif kind == "lastFrameKept":
            last_frames_kept.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "frame": payload.get("frame"),
                    "outputBytes": _number(payload.get("outputBytes")),
                }
            )
        elif kind == "artifactSource" and payload.get("consumer") == "persistent-cache":
            cache_handoffs.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "action": payload.get("action"),
                    "bytes": _number(payload.get("bytes")),
                    "handoffMicros": _number(payload.get("handoffMicros")),
                }
            )

    source_reads.sort(key=lambda row: row["streamMicros"], reverse=True)

    def max_concurrency(rows: list[dict[str, Any]]) -> int:
        boundaries: list[tuple[int, int]] = []
        for row in rows:
            end = _number(row.get("t"))
            start = max(0, end - _number(row.get("streamMicros")))
            boundaries.append((start, 1))
            boundaries.append((end, -1))
        active = 0
        maximum = 0
        for _, delta in sorted(boundaries, key=lambda item: (item[0], item[1])):
            active += delta
            maximum = max(maximum, active)
        return maximum

    if has_process_clock:
        max_concurrent_reads = max_concurrency(source_reads)
        concurrency_scope = "process"
    else:
        reads_by_session: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for row in source_reads:
            reads_by_session[str(row.get("sessionId", ""))].append(row)
        max_concurrent_reads = max(
            (max_concurrency(rows) for rows in reads_by_session.values()),
            default=0,
        )
        concurrency_scope = "per-session-legacy-clock"
    return {
        "trace": str(path),
        "eventCount": len(rows),
        "reasonCounts": dict(reasons),
        "presentationPathCounts": dict(paths),
        "dominantStageCounts": dict(dominant),
        "recordedDominantStageCounts": dict(recorded_dominant),
        "endToEndMicros": _stats(end_to_end),
        "presentMicros": _stats(present),
        "stages": {field: _stats(values) for field, values in stages.items()},
        "frames": rows,
        "taskFailureCount": len(failures),
        "taskFailures": failures,
        "blitLockFailureCount": sum(
            1 for failure in failures if failure.get("blitStatus") == 4
        ),
        "blitFallbackCount": sum(
            1 for failure in failures if failure.get("fallback") == "flutterImage"
        ),
        "platformConfigureMicros": _stats(
            [row["platformConfigureMicros"] for row in rows]
        ),
        "blitRetryCount": sum(row["blitRetryCount"] for row in rows),
        "surfaceReconfigureCount": sum(
            row["surfaceReconfigureCount"] for row in rows
        ),
        "sourceReadCount": len(source_reads),
        "sourceReadMicros": _stats([row["streamMicros"] for row in source_reads]),
        "sourceReadModeCounts": dict(
            Counter(
                str(row["artifactReadMode"])
                for row in source_reads
                if row["artifactReadMode"] is not None
            )
        ),
        "sourceDeliveryModeCounts": dict(
            Counter(
                str(row["deliveryMode"])
                for row in source_reads
                if row["deliveryMode"] is not None
            )
        ),
        "sourceMemoryCacheHits": sum(
            1 for row in source_reads if row["memoryCacheHit"] is True
        ),
        "sourceMemoryCacheJoins": sum(
            1 for row in source_reads if row["memoryCacheJoined"] is True
        ),
        "sourceArtifactMaterializeMicros": _stats(
            [row["artifactMaterializeMicros"] for row in source_reads]
        ),
        "sourceReadSchedulerWaitMicros": _stats(
            [row["readSchedulerWaitMicros"] for row in source_reads]
        ),
        "sourceReadSchedulerMaxWaitMicros": _stats(
            [row["readSchedulerMaxWaitMicros"] for row in source_reads]
        ),
        "sourceReadSchedulerAcquires": _stats(
            [row["readSchedulerAcquires"] for row in source_reads]
        ),
        "sourceReadSchedulerForegroundAcquires": _stats(
            [row["readSchedulerForegroundAcquires"] for row in source_reads]
        ),
        "sourceReadSchedulerPressureHolds": _stats(
            [row["readSchedulerPressureHolds"] for row in source_reads]
        ),
        "sourceMaxConcurrentReads": max_concurrent_reads,
        "sourceConcurrencyScope": concurrency_scope,
        "processClock": has_process_clock,
        "readerSessionLifecycle": dict(session_lifecycle),
        "cacheHandoffActionCounts": dict(
            Counter(str(row["action"]) for row in cache_handoffs)
        ),
        "cacheHandoffMicros": _stats(
            [row["handoffMicros"] for row in cache_handoffs]
        ),
        "cacheHandoffs": cache_handoffs,
        "decodeRefillCount": len(decode_refills),
        "decodeRefillRoleCounts": dict(
            Counter(str(row["role"]) for row in decode_refills)
        ),
        "decodeRefillStageCounts": dict(
            Counter(str(row["stage"]) for row in decode_refills)
        ),
        "decodeRefills": decode_refills,
        "decodeRecoveryCount": len(decode_recoveries),
        "decodeRecoveryAttemptCounts": dict(
            Counter(str(row["attempt"]) for row in decode_recoveries)
        ),
        "decodeRecoveries": decode_recoveries,
        "decodePrefixHintCount": len(decode_prefix_hints),
        "decodePrefixHints": decode_prefix_hints,
        "rankedDownloadCount": len(ranked_downloads),
        "rankedDownloadMaxGlobalActive": max(
            (row["globalActive"] for row in ranked_downloads),
            default=0,
        ),
        "rankedDownloadBucketCounts": dict(
            Counter(str(row["bucket"]) for row in ranked_downloads)
        ),
        "rankedDownloads": ranked_downloads,
        "lastFrameKeptCount": len(last_frames_kept),
        "lastFramesKept": last_frames_kept,
        "cacheResidentCommitCount": len(cache_resident_commits),
        "cacheResidentIngressMicros": _stats(
            [row["nativeIngressMicros"] for row in cache_resident_commits]
        ),
        "cacheResidentArtifactWriteMicros": _stats(
            [row["artifactWriteMicros"] for row in cache_resident_commits]
        ),
        "cacheResidentCommits": cache_resident_commits,
        "textureLeasePresentationCount": len(texture_presentations),
        "textureLeaseReuseCount": sum(
            1 for row in texture_presentations
            if row["textureLeaseReused"] is True
        ),
        "textureLeasePresentations": texture_presentations,
        "sourceFirstChunkMicros": _stats(
            [row["firstChunkMicros"] for row in source_reads]
        ),
        "sourceMaxChunkGapMicros": _stats(
            [row["maxChunkGapMicros"] for row in source_reads]
        ),
        "sourceReads": source_reads,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("--limit", type=int, default=24)
    args = parser.parse_args()
    report = summarize(args.trace)
    if args.as_json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    print(f"framePipelineTiming events: {report['eventCount']}")
    print(f"reasons: {report['reasonCounts']}")
    print(f"paths: {report['presentationPathCounts']}")
    print(f"recorded dominant stages: {report['recordedDominantStageCounts']}")
    print(f"normalized dominant stages: {report['dominantStageCounts']}")
    print(f"end-to-end µs: {report['endToEndMicros']}")
    print(f"present µs: {report['presentMicros']}")
    print(
        f"source reads: {report['sourceReadCount']} "
        f"maxConcurrent={report['sourceMaxConcurrentReads']} "
        f"scope={report['sourceConcurrencyScope']} "
        f"schedulerWait={report['sourceReadSchedulerWaitMicros']} "
        f"pressureHolds={report['sourceReadSchedulerPressureHolds']} "
        f"modes={report['sourceReadModeCounts']} "
        f"delivery={report['sourceDeliveryModeCounts']} "
        f"memoryHits={report['sourceMemoryCacheHits']} "
        f"memoryJoins={report['sourceMemoryCacheJoins']} "
        f"materialize={report['sourceArtifactMaterializeMicros']} "
        f"stream={report['sourceReadMicros']} "
        f"firstChunk={report['sourceFirstChunkMicros']} "
        f"maxGap={report['sourceMaxChunkGapMicros']}"
    )
    print(
        f"task failures: {report['taskFailureCount']} "
        f"blitLock={report['blitLockFailureCount']} "
        f"fallback={report['blitFallbackCount']} "
        f"legacyConfigure={report['platformConfigureMicros']} "
        f"legacyBlitRetries={report['blitRetryCount']} "
        f"surfaceReconfigures={report['surfaceReconfigureCount']}"
    )
    print(f"reader lifecycle: {report['readerSessionLifecycle']}")
    print(
        "decode refills: "
        f"count={report['decodeRefillCount']} "
        f"roles={report['decodeRefillRoleCounts']} "
        f"stages={report['decodeRefillStageCounts']}"
    )
    print(
        "decode recoveries: "
        f"count={report['decodeRecoveryCount']} "
        f"attempts={report['decodeRecoveryAttemptCounts']}"
    )
    print(f"decode prefix hints: {report['decodePrefixHintCount']}")
    print(
        "ranked downloads: "
        f"count={report['rankedDownloadCount']} "
        f"maxGlobal={report['rankedDownloadMaxGlobalActive']} "
        f"buckets={report['rankedDownloadBucketCounts']}"
    )
    print(f"last frames kept: {report['lastFrameKeptCount']}")
    print(
        "cache-resident ingress: "
        f"count={report['cacheResidentCommitCount']} "
        f"native={report['cacheResidentIngressMicros']} "
        f"artifactWrite={report['cacheResidentArtifactWriteMicros']}"
    )
    print(
        "texture lease presentations: "
        f"count={report['textureLeasePresentationCount']} "
        f"reused={report['textureLeaseReuseCount']}"
    )
    print(
        f"cache handoff: actions={report['cacheHandoffActionCounts']} "
        f"timing={report['cacheHandoffMicros']}"
    )
    for failure in report["taskFailures"][: max(0, args.limit)]:
        print(
            "  failure "
            f"t={failure['t']} lane={failure['lane']} role={failure['role']} "
            f"queue={failure['laneQueueMicros']} "
            f"execution={failure['executionMicros']} "
            f"elapsed={failure['taskElapsedMicros']} "
            f"failureClass={failure['failureClass']} "
            f"source={failure['sourceLength']}/"
            f"{failure['requiredSourceLength']} "
            f"sealed={failure['sourceSealed']} error={failure['error']}"
        )
    print("frames:")
    for row in report["frames"][: max(0, args.limit)]:
        print(
            "  "
            f"t={row['t']} session={row['sessionId']} frame={row['frame']} "
            f"cycle={row['cycle']} ordinal={row['ordinal']} role={row['role']} "
            f"decodedRole={row['decodedRole']} uploadRole={row['uploadRole']} "
            f"reason={row['reason']} dominant={row['dominantStage']}:"
            f"{row['dominantStageMicros']} "
            f"recorded={row['recordedDominantStage']} "
            f"lead={row['decodedLeadMicros']} "
            f"backpressure={row['uploadBackpressureMicros']} "
            f"endToEnd={row['endToEndMicros']} "
            f"present={row['presentMicros']} deadlineMiss={row['deadlineMissMicros']} "
            f"legacyConfigure={row['platformConfigureMicros']} "
            f"legacyBlitRetries={row['blitRetryCount']} "
            f"surfaceReconfigures={row['surfaceReconfigureCount']} "
            f"path={row['presentationPath']}"
        )
    print("slow source reads:")
    for row in report["sourceReads"][: max(0, args.limit)]:
        print(
            "  "
            f"t={row['t']} source={row['source']} class={row['sourceClass']} "
            f"consumer={row['consumer']} priority={row['priority']} "
            f"mode={row['artifactReadMode']} memoryHit={row['memoryCacheHit']} "
            f"joined={row['memoryCacheJoined']} "
            f"materialize={row['artifactMaterializeMicros']} "
            f"hotEntries={row['hotCacheEntries']} hotBytes={row['hotCacheBytes']} "
            f"bytes={row['bytes']} chunks={row['chunks']} "
            f"schedulerWait={row['readSchedulerWaitMicros']} "
            f"schedulerMaxWait={row['readSchedulerMaxWaitMicros']} "
            f"schedulerAcquires={row['readSchedulerAcquires']} "
            f"foregroundAcquires={row['readSchedulerForegroundAcquires']} "
            f"pressureHolds={row['readSchedulerPressureHolds']} "
            f"delivery={row['deliveryMode']} "
            f"firstChunk={row['firstChunkMicros']} stream={row['streamMicros']} "
            f"maxGap={row['maxChunkGapMicros']} maxChunk={row['maxChunkBytes']}"
        )


if __name__ == "__main__":
    main()
