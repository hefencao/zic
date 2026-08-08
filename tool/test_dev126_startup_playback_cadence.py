#!/usr/bin/env python3
"""Guard the dev.126 deadline wake while acknowledging dev.132 supersession."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda path: (ROOT / path).read_text(encoding="utf-8")

upload = read("packages/sessions/lib/src/upload_session.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
runtime = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
check = read("tool/check.sh")

for forbidden in (
    "bool _startupBuffering",
    "_startupBufferingCurrent",
    "isStartupBuffering",
    "decode-startup-deferred",
):
    if forbidden in upload or forbidden in coordinator or forbidden in runtime:
        raise SystemExit(f"dev.132 must keep the superseded startup gate removed: {forbidden}")
for required in (
    "_uploads.earliestPlaybackDeadlineMicros(ids)",
    "Duration(microseconds: remainingMicros > 0 ? remainingMicros : 0)",
):
    if required not in runtime:
        raise SystemExit(f"deadline-driven playback wake is missing: {required}")
if "Timer.periodic(" in runtime:
    raise SystemExit("periodic playback ticker must remain superseded")
if "playbackLeadMicros" not in upload:
    raise SystemExit("deadline lead accounting must remain available")
if "test_dev126_startup_playback_cadence.py" not in check:
    raise SystemExit("repository check lost dev.126 compatibility gate")
print("dev.126 deadline wake / dev.132 startup-gate supersession: OK")
