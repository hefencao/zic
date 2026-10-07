#!/usr/bin/env python3
"""Guard dev.124 current-prefix startup and patch delivery contracts."""
from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.124 contract: {token}")


session = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
profile = read("packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart")
ownership_test = read("packages/pipeline_runtime/test/media_runtime_ownership_test.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
delivery = read("docs/AI_ITERATION_PROMPT.md")
check = read("tool/check.sh")
adr = read("docs/archive/adr/0108-startup-current-prefix-exact-output-prewarm.md")

for token in (
    "final target = binding.pipeline.decodeTarget",
    "width: size.width",
    "height: size.height",
    "downloadBucketLimitFor: _profile.downloadBucketLimit",
):
    require(session, token, "Pipeline exact output prewarm / stable bucket boundary")
for forbidden in (
    "_startupCurrentDownload",
    "_startupFirstOutputReady",
    "_releaseStartupCurrentDownload",
    "currentBucket == 'local'",
):
    if forbidden in session:
        raise SystemExit(
            f"first-output presentation state must not rewrite NetLane bucket policy: {forbidden}"
        )
for token in (
    "localSourceConcurrency: 2",
    "remoteSourceConcurrency: 5",
):
    require(profile, token, "stable Reader source concurrency")
for token in (
    "current output prewarms the exact aligned decoded raster",
    "await runtime.firstPrewarm.future",
    "PipelineMediaRuntime, PipelineOutputPrewarmer",
):
    require(ownership_test, token, "exact output prewarm owner test")
for token in (
    '"mountToFirstFrameMicros"',
    '"startupLocalDownloadMaxBucketActive"',
    '"startupLocalDownloadBucketLimits"',
    '"startupFirstTextureLeaseReuseCount"',
    '"startupFirstSurfaceReconfigureCount"',
):
    require(analyzer, token, "startup Trace analyzer")
for token in (
    "baseline-to-release patch generated for `git apply --index`",
    "Resolve `patch_dir` from `ZIC_PATCH_DIR` or the local `.zic-workspace.json`",
    "must not be included in release ZIPs or generated patches",
):
    require(delivery, token, "release delivery rules")
require(check, "test_dev124_startup_current_prefix_patch_delivery.py", "repository check")
require(adr, "**状态：Superseded**", "dev.124 startup bucket ADR status")

environment_patch_dir = "../dev124-test-patches"
resolved = subprocess.check_output(
    ["python3", str(ROOT / "tool/workspace_config.py"), "patch_dir"],
    text=True,
    env={"ZIC_PATCH_DIR": environment_patch_dir},
).strip()
if resolved != environment_patch_dir:
    raise SystemExit("workspace_config.py did not honor ZIC_PATCH_DIR")
if ".zic-workspace.json" not in read(".gitignore"):
    raise SystemExit("machine-local workspace config must be gitignored")
if "PageRole.visible" in read("packages/pipeline/lib/src/role_window.dart"):
    raise SystemExit("dev.124 must not reintroduce visible-page demand")

print("dev.124 startup current-prefix/patch delivery contract: OK")
