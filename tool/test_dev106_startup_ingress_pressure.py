#!/usr/bin/env python3
"""Guard the post-dev.106 local-read pressure ownership boundary."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing local-read pressure contract: {token}")


scheduler = read("packages/downloads/lib/src/artifact_cache_read_scheduler.dart")
pipeline = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
scheduler_test = read("packages/downloads/test/artifact_cache_read_scheduler_test.dart")
check = read("tool/check.sh")
adr = read("docs/adr/0090-startup-foreground-pressure-whole-body-ingress.md")

for token in (
    "int _activeForeground = 0;",
    "_isForeground(pending.currentPriority)",
    "_activeForeground > 0",
    "maxBackgroundWhileForeground",
):
    require(scheduler, token, "artifact read scheduler")

for forbidden in (
    "_startupArtifactPressure",
    "_holdStartupArtifactPressureFor",
    "reserveFirstForegroundQuantum",
    "artifactReadScheduler.holdForegroundPressure(",
):
    if forbidden in pipeline:
        raise SystemExit(
            f"Pipeline presentation must not pre-arm local-read pressure: {forbidden}"
        )

for token in (
    "foreground pressure limits simultaneous background quanta",
    "queued foreground work outranks queued background work",
):
    require(scheduler_test, token, "scheduler owner test")
require(check, "test_dev106_startup_ingress_pressure.py", "repository check")
require(adr, "**状态：Superseded**", "dev.106 ADR status")

print("post-dev.106 local-read pressure ownership: OK")
