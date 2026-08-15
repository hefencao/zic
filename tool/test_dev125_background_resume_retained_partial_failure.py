#!/usr/bin/env python3
"""Guard dev.125 retained resume output and partial-failure boundaries."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.125 contract: {token}")

media = read("packages/media/lib/src/output.dart")
upload = read("packages/sessions/lib/src/upload_session.dart")
runtime = read("packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart")
presenter = read("packages/texture_bridge/lib/src/android_texture_presenter.dart")
kotlin = read("packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt")
cursor = read("packages/bridge/lib/src/native_cursor.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
workspace = read("tool/workspace_config.py")
delivery = read("docs/AI_ITERATION_PROMPT.md")
gitignore = read(".gitignore")
check = read("tool/check.sh")

# ADR 0113 supersedes and removes cross-Reader retained platform output.
for forbidden, owner in (
    ("RetainedOutputUploader", media + upload + runtime),
    ("restoreRetainedOutput", media + upload + runtime),
    ("_retainedRestoreAttempted", upload),
    ("final class _RetainedTextureFrame", runtime),
    ("final class _RetainedAndroidTextureOutputFrame", runtime),
):
    if forbidden in owner:
        raise SystemExit(
            f"cross-Reader retained output was superseded by dev.129: {forbidden}"
        )
for token in (
    "await value.lease.release()",
    "Future<void> releaseIdle() async",
):
    require(runtime, token, "Android fresh texture lifecycle")
require(presenter, "Future<void> redraw()", "Android texture presenter")
for token in ('"redraw" -> redraw(call, result)', "fun redraw()"):
    require(kotlin, token, "Android texture bridge redraw")
for token in (
    "if (!_source.sealed)",
    "return const CursorStep.needMoreData()",
    "if (!_source.sealed) return false",
):
    require(cursor, token, "partial native cursor boundary")
for token in (
    "'stage': 'decode-source-growth'",
    "'waitForSourceRevision': true",
    "if (existing?.sourceSealed == false)",
):
    require(coordinator, token, "partial decode recovery boundary")
for token in (
    '"retainedOutputRestoreCount"',
    '"decodeSourceGrowthWaitCount"',
):
    require(analyzer, token, "resume/partial Trace analyzer")
for token in (
    'os.environ.get("ZIC_PATCH_DIR"',
    ".zic-workspace.json in the local workspace",
):
    require(workspace, token, "local workspace config")
require(gitignore, ".zic-workspace.json", "gitignored local config")
for token in (
    "must not be included in release ZIPs or generated patches",
    "ZIC_PATCH_DIR",
):
    require(delivery, token, "release delivery rules")
require(check, "test_dev125_background_resume_retained_partial_failure.py", "repository check")
if "PageRole.visible" in read("packages/pipeline/lib/src/role_window.dart"):
    raise SystemExit("dev.125 must not restore visible-page demand")
print("dev.125 background resume/partial failure contract: OK")
