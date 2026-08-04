#!/usr/bin/env python3
"""Guard dev.127 startup-buffer staged-refill closure."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.127 contract: {token}")

coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
runtime = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
owner_test = read("packages/sessions/test/live_coordinator_test.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
agents = read("AGENTS.md")
check = read("tool/check.sh")

for token in (
    "void refreshDecodeScheduling(String sessionId, {DecodeId? only})",
    "final sameStartupCurrent = decision.id == except &&",
    "uploads?.isStartupBuffering(decision.id)",
    "if (decision.id == except && !sameStartupCurrent)",
):
    require(coordinator, token, "LiveCoordinator startup refill chaining")

if coordinator.count("animation.frameCount <= 1 &&") != 1:
    raise SystemExit(
        "static single-frame satisfaction must not contain duplicated conditions"
    )

for token in (
    "snapshot.state == UploadState.ready &&",
    "_uploads.isStartupBuffering(id)",
    "_coordinator.refreshDecodeScheduling(sessionId, only: id)",
):
    require(runtime, token, "Pipeline upload-to-decode wake")

for token in (
    "startup buffering chains current through later staged waterlines",
    "containsAllInOrder(<Object?>['c>2', 'c>4', 'c>6'])",
    "coordinator.refreshDecodeScheduling('reader', only: decodeId)",
):
    require(owner_test, token, "sessions owner test")

for token in (
    '"playbackBufferingOutstandingCount"',
    '"playbackBufferingOutstanding"',
    '"playbackBufferingWaitMicros"',
):
    require(analyzer, token, "Trace analyzer startup-buffer diagnostics")

require(
    agents,
    '"$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"',
    "patch command policy",
)
require(check, "test_dev127_startup_buffer_refill_closure.py", "repository check")
print("dev.127 startup-buffer refill closure contract: OK")
