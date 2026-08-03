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
    "platformBlitMicros",
    "platformScheduleMicros",
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
    "platformBlit": "platformBlitMicros",
    "platformSchedule": "platformScheduleMicros",
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
    next_due_by_session: dict[str, int] = {}

    for event in _events(path):
        kind = event.get("kind")
        payload = event.get("payload")
        if not isinstance(payload, dict):
            payload = {}
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
            platform_upload = _number(payload.get("platformUploadMicros"))
            if platform_upload > 0:
                normalized_payload["platformOtherMicros"] = max(
                    0,
                    platform_upload
                    - _number(payload.get("platformQueueMicros"))
                    - _number(payload.get("platformRetainMicros"))
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
                }
            )
            presented_at = _number(payload.get("presentedAtMicros"))
            duration = _number(payload.get("durationMicros"))
            if presented_at > 0 and duration > 0:
                next_due_by_session[session_id] = presented_at + duration
            elif duration <= 0:
                next_due_by_session.pop(session_id, None)
        elif kind == "taskFailed":
            failures.append(
                {
                    "t": event.get("t"),
                    "sessionId": event.get("sessionId"),
                    "identityHash": event.get("identityHash"),
                    "lane": payload.get("lane"),
                    "role": payload.get("role"),
                    "error": payload.get("error"),
                    "laneQueueMicros": _number(payload.get("laneQueueMicros")),
                    "executionMicros": _number(payload.get("executionMicros")),
                    "taskElapsedMicros": _number(payload.get("taskElapsedMicros")),
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
                    "bytes": _number(payload.get("bytes")),
                    "chunks": _number(payload.get("chunks")),
                    "openMicros": _number(payload.get("openMicros")),
                    "firstChunkMicros": _number(payload.get("firstChunkMicros")),
                    "streamMicros": _number(payload.get("streamMicros")),
                    "maxChunkGapMicros": _number(payload.get("maxChunkGapMicros")),
                    "maxChunkBytes": _number(payload.get("maxChunkBytes")),
                    "completed": payload.get("completed"),
                }
            )

    source_reads.sort(key=lambda row: row["streamMicros"], reverse=True)
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
        "sourceReadCount": len(source_reads),
        "sourceReadMicros": _stats([row["streamMicros"] for row in source_reads]),
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
        f"stream={report['sourceReadMicros']} "
        f"firstChunk={report['sourceFirstChunkMicros']} "
        f"maxGap={report['sourceMaxChunkGapMicros']}"
    )
    print(f"task failures: {report['taskFailureCount']}")
    for failure in report["taskFailures"][: max(0, args.limit)]:
        print(
            "  failure "
            f"t={failure['t']} lane={failure['lane']} role={failure['role']} "
            f"queue={failure['laneQueueMicros']} "
            f"execution={failure['executionMicros']} "
            f"elapsed={failure['taskElapsedMicros']} error={failure['error']}"
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
            f"path={row['presentationPath']}"
        )
    print("slow source reads:")
    for row in report["sourceReads"][: max(0, args.limit)]:
        print(
            "  "
            f"t={row['t']} source={row['source']} class={row['sourceClass']} "
            f"consumer={row['consumer']} bytes={row['bytes']} chunks={row['chunks']} "
            f"firstChunk={row['firstChunkMicros']} stream={row['streamMicros']} "
            f"maxGap={row['maxChunkGapMicros']} maxChunk={row['maxChunkBytes']}"
        )


if __name__ == "__main__":
    main()
