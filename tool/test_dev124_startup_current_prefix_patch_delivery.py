#!/usr/bin/env python3
"""Guard dev.124 current-prefix startup and patch delivery contracts."""
from __future__ import annotations

import json
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
agents = read("AGENTS.md")
check = read("tool/check.sh")
workspace = json.loads(read(".zic-workspace.json"))

for token in (
    "final target = binding.pipeline.decodeTarget",
    "width: target.physicalWidth",
    "height: target.physicalHeight",
    "DownloadId? _startupCurrentDownload",
    "currentBucket == 'local' && _profile.downloadBucket(id) == 'local'",
    "? 1",
    "_startupFirstOutputReady(current)",
    "upload.state == UploadState.ready && upload.presentClaims > 0",
    "_coordinator.refreshDownloadScheduling(sessionId)",
    "_releaseStartupCurrentDownload();",
):
    require(session, token, "Pipeline startup current-source gate")
for token in (
    "void refreshDownloadScheduling(String sessionId)",
    "_ensureDownloadTask(sessionId, entry.key, session)",
):
    require(coordinator, token, "download scheduling refresh")
for token in (
    "localSourceConcurrency: 2",
    "remoteSourceConcurrency: 5",
):
    require(profile, token, "stable Reader source concurrency")
for token in (
    "current output prewarms the exact aligned decode target",
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
    "Read `patch_dir` from `.zic-workspace.json`",
):
    require(agents, token, "release delivery rules")
require(check, "test_dev124_startup_current_prefix_patch_delivery.py", "repository check")

if workspace != {
    "schema": "zic-workspace-v1",
    "patch_dir": "../zic-patches",
}:
    raise SystemExit(f"unexpected workspace delivery config: {workspace!r}")
resolved = subprocess.check_output(
    ["python3", str(ROOT / "tool/workspace_config.py"), "patch_dir"],
    text=True,
).strip()
if resolved != workspace["patch_dir"]:
    raise SystemExit("workspace_config.py did not return configured patch_dir")
if "PageRole.visible" in read("packages/pipeline/lib/src/role_window.dart"):
    raise SystemExit("dev.124 must not reintroduce visible-page demand")

print("dev.124 startup current-prefix/patch delivery contract: OK")
