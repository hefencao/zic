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


def summarize(path: Path) -> dict[str, Any]:
    dominant = Counter()
    reasons = Counter()
    paths = Counter()
    stages: dict[str, list[int]] = defaultdict(list)
    end_to_end: list[int] = []
    present: list[int] = []
    rows: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    source_reads: list[dict[str, Any]] = []

    for event in _events(path):
        kind = event.get("kind")
        payload = event.get("payload")
        if not isinstance(payload, dict):
            payload = {}
        if kind == "framePipelineTiming":
            dominant[str(payload.get("dominantStage", "unknown"))] += 1
            reasons[str(payload.get("traceReason", "unknown"))] += 1
            paths[str(payload.get("presentationPath", "unknown"))] += 1
            for field in STAGE_FIELDS:
                stages[field].append(_number(payload.get(field)))
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
                    "reason": payload.get("traceReason"),
                    "dominantStage": payload.get("dominantStage"),
                    "dominantStageMicros": _number(payload.get("dominantStageMicros")),
                    "endToEndMicros": _number(payload.get("endToEndMicros")),
                    "presentMicros": _number(payload.get("presentMicros")),
                    "deadlineMissMicros": _number(payload.get("deadlineMissMicros")),
                    "presentationPath": payload.get("presentationPath"),
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
    print(f"dominant stages: {report['dominantStageCounts']}")
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
            f"reason={row['reason']} dominant={row['dominantStage']}:"
            f"{row['dominantStageMicros']} endToEnd={row['endToEndMicros']} "
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
