#!/usr/bin/env python3
"""Guard dev.111 buffered decode recovery after startup scheduling changed."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.111 contract: {token}")


decode = read("packages/sessions/lib/src/decode_session.dart")
upload = read("packages/sessions/lib/src/upload_session.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")
adr = read("docs/adr/0095-buffered-decode-recovery-startup-near-pressure.md")

for token in (
    "_restartCursorWhenHolderEmpty = true;",
    "A successful successor proves that the existing cursor recovered",
):
    require(decode, token, "decode session recovery")
for token in (
    "decodeSnapshot.state == DecodeState.failed &&",
    "holder == null || holder.isEmpty",
    "must not discard already decoded successors",
):
    require(upload, token, "upload buffered continuity")
for token in (
    "_scheduleDecodeRecovery",
    "'stage': 'decode-recovery'",
    "'bufferedDepth'",
    "attempt > 4",
):
    require(coordinator, token, "live decode recovery")
for token in (
    '"decodeRecoveryCount"',
    '"decodeRecoveryAttemptCounts"',
):
    require(analyzer, token, "trace analyzer")
for path, token in (
    ("packages/sessions/test/decode_session_test.dart",
     "transient cursor failure retries in place while successors remain"),
    ("packages/sessions/test/upload_session_test.dart",
     "buffered successors continue after a transient decode failure"),
):
    require(read(path), token, path)
require(check, "test_dev111_decode_recovery_startup_pressure.py", "repository check")
require(adr, "**状态：Superseded**", "dev.111 ADR status")
require(adr, "ADR 0096", "dev.111 superseding decision")
for path in (
    "docs/adr/0095-buffered-decode-recovery-startup-near-pressure.md",
    "docs/audits/dev111-decode-recovery-startup-pressure-audit.md",
    "docs/audits/dev111-validation-results.md",
):
    if not (ROOT / path).is_file():
        raise SystemExit(f"dev.111 evidence is missing: {path}")
print("dev.111 buffered decode recovery contract: OK")
