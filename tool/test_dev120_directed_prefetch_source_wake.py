#!/usr/bin/env python3
"""Guard dev.120 directed prefetch source-wake execution."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.120 contract: {token}")

coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
coordinator_test = read("packages/sessions/test/live_coordinator_test.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
analyzer_test = read("tool/test_frame_pipeline_trace_analyzer.py")
check = read("tool/check.sh")

for text, token, owner in (
    (coordinator, "final pendingSourceWake = sourceRevision > observedSourceRevision", "source revision execution"),
    (coordinator, "_nextDecodeRefill(only: pendingSourceWake ? id : null)", "directed source refill"),
    (coordinator, "DecodeRefillDecision? _nextDecodeRefill({DecodeId? only})", "directed refill API"),
    (coordinator, "if (only != null && id != only)", "directed eligibility"),
    (coordinator, "'sourceWake': pendingSourceWake", "source-wake trace"),
    (coordinator, "'consumedSourceRevision': observedSourceRevision", "source revision trace"),
    (coordinator_test, "source-ready prefetch refill is directed to its own decode id", "coordinator owner test"),
    (coordinator_test, "await prefetchDecoded.future.timeout", "prefetch-before-current-release assertion"),
    (analyzer, '"decodeRefillSourceWakeCount"', "trace analyzer"),
    (analyzer_test, 'assert report["decodeRefillSourceWakeCount"] == 1', "trace analyzer test"),
    (check, "test_dev120_directed_prefetch_source_wake.py", "repository check"),
):
    require(text, token, owner)

if "_nextDecodeRefill(only: sourceWake ? id : null)" in coordinator:
    raise SystemExit("directed refill still trusts the stale submitted sourceWake flag")

print("dev.120 directed prefetch source wake contract: OK")
