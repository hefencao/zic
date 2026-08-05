#!/usr/bin/env python3
"""Guard dev.131 diagnostics while dev.132 removes the cause, not the metrics."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
coordinator = (ROOT / "packages/sessions/lib/src/live_coordinator.dart").read_text()
upload = (ROOT / "packages/sessions/lib/src/upload_session.dart").read_text()
pool = (ROOT / "packages/bridge/lib/src/native_decode_pool.dart").read_text()
analyzer = (ROOT / "tool/analyze_frame_pipeline_trace.py").read_text()

for forbidden in (
    "decode-startup-deferred",
    "startupBuffering",
    "_startupBufferSatisfied",
):
    if forbidden in coordinator or forbidden in upload:
        raise SystemExit(f"dev.132 startup/rebuffer cause remains: {forbidden}")
if "if (worker.executionClass == DecodeExecutionClass.current)" not in pool:
    raise SystemExit("native current promotion must remain idempotent")
for metric in ("playbackRebufferCount", "decodeStartupDeferredCount"):
    if metric not in analyzer:
        raise SystemExit(f"historical trace diagnostic was removed: {metric}")
print("dev.131 diagnostics with dev.132 holder-driven supersession: OK")
