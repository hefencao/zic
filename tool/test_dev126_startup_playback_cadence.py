#!/usr/bin/env python3
"""Guard dev.126 startup playback buffering and deadline-lead ownership."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.126 contract: {token}")

upload = read("packages/sessions/lib/src/upload_session.dart")
registry = read("packages/sessions/lib/src/upload_registry.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
runtime = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
trace = read("packages/telemetry/lib/src/trace.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
owner_test = read("packages/sessions/test/upload_session_test.dart")
check = read("tool/check.sh")

for token in (
    "bool _startupBuffering = false;",
    "final target = (250000 / durationMicros).ceil();",
    "if (target > 7) return 7;",
    "animation.frameCount >= 7",
    "TraceEventKind.playbackBuffering",
    "void _maybeEnterStartupBuffer(UploadDemand demand)",
    "void _maybeReleaseStartupBuffer(UploadDemand demand)",
    "playbackLeadMicros",
    "leadMicros: (visibleAtMicros - presentStartedAt)",
):
    require(upload, token, "UploadSession startup cadence")
require(registry, "bool isStartupBuffering(DecodeId id)", "UploadRegistry projection")
for token in (
    "DecodeId? _startupBufferingCurrent()",
    "final startupCurrent = _startupBufferingCurrent();",
    "if (startupCurrent != null && id != startupCurrent)",
):
    require(coordinator, token, "LiveCoordinator startup refill gate")
require(
    runtime,
    "const Duration(milliseconds: 4)",
    "active playback ticker",
)
require(trace, "playbackBuffering,", "Trace event schema")
for token in (
    '"playbackBufferingCount"',
    '"playbackBufferingReadyCount"',
    '"playbackBuffering"',
):
    require(analyzer, token, "Trace analyzer")
for token in (
    "current animation waits for startup successors before playback",
    "expect(upload.startupBuffering, isTrue);",
    "<Object?>['waiting', 'ready']",
):
    require(owner_test, token, "UploadSession owner test")
require(check, "test_dev126_startup_playback_cadence.py", "repository check")

# The startup gate must stay in sessions; Reader and texture bridge cannot own
# buffering timers or frame queues.
for path in (
    "packages/reader/lib/src/reader_view.dart",
    "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
    "packages/texture_bridge/lib/src/android_texture_presenter.dart",
):
    text = read(path)
    if "startupBuffering" in text or "playbackBuffering" in text:
        raise SystemExit(f"startup playback ownership leaked into {path}")

print("dev.126 startup playback cadence contract: OK")
