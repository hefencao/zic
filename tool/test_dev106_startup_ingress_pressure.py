#!/usr/bin/env python3
"""Guard dev.106 startup foreground pressure and whole-body artifact ingress."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.106 contract: {token}")


scheduler = read("packages/downloads/lib/src/artifact_cache_read_scheduler.dart")
pipeline = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
scheduler_test = read("packages/downloads/test/artifact_cache_read_scheduler_test.dart")
check = read("tool/check.sh")
adr = read("docs/adr/0090-startup-foreground-pressure-whole-body-ingress.md")

for token in (
    "int _foregroundPressureHolds = 0;",
    "ArtifactCachePressureLease holdForegroundPressure()",
    "_foregroundPressureHolds > 0 || _activeForeground > 0",
    "final class ArtifactCachePressureLease",
):
    require(scheduler, token, "artifact read scheduler")

for token in (
    "_holdStartupArtifactPressureFor(currentDownload);",
    "binding.accept(observation);",
    "artifactReadScheduler.holdForegroundPressure()",
    "upload.presentClaims <= 0",
    "decode.depth > 3",
    "_maybeReleaseStartupArtifactPressure();",
    "_releaseStartupArtifactPressure();",
):
    require(pipeline, token, "pipeline Reader startup pressure")
if pipeline.index("_holdStartupArtifactPressureFor(currentDownload);") > pipeline.index(
    "binding.accept(observation);"
):
    raise SystemExit("startup pressure must be established before binding.accept")

require(
    scheduler_test,
    "external foreground pressure reserves background capacity",
    "scheduler owner test",
)
require(check, "test_dev106_startup_ingress_pressure.py", "repository check")
require(adr, "**状态：Superseded**", "dev.106 ADR status")
require(adr, "ADR 0091", "dev.106 superseding decision")

for path in (
    "docs/adr/0090-startup-foreground-pressure-whole-body-ingress.md",
    "docs/audits/dev106-startup-ingress-pressure-audit.md",
    "docs/audits/dev106-validation-results.md",
):
    if not (ROOT / path).is_file():
        raise SystemExit(f"dev.106 evidence is missing: {path}")

print("dev.106 startup ingress pressure: OK")
