#!/usr/bin/env python3
"""Regression checks for the real-device Reader preflight contract."""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool"))

import prepare_reader_device_test as preflight  # noqa: E402


assert preflight.apk_path("profile", "arm64-v8a").name == (
    "app-arm64-v8a-profile.apk"
)
assert preflight.apk_path("debug", "armeabi-v7a").name == (
    "app-armeabi-v7a-debug.apk"
)
assert preflight.DEFAULT_TIMEOUT_SECONDS["debug"] > (
    preflight.DEFAULT_TIMEOUT_SECONDS["profile"]
)

bootstrap_only = """
[zic-startup] visible-home-window-complete
[zic-home] initialize-complete mode=bootstrap-snapshot-only
"""
assert not preflight.readiness_markers_present(bootstrap_only)
assert not preflight.readiness_markers_present(
    bootstrap_only + "\n[zic-startup] durable-services-ready\n"
)
authoritative = bootstrap_only + """
[zic-startup] durable-services-ready
[zic-home] services-handoff-complete mode=authoritative-reload entries=62 saved=74
"""
assert preflight.readiness_markers_present(authoritative)
revision_fast_path = bootstrap_only + """
[zic-startup] durable-services-ready
[zic-home] services-handoff-complete mode=revision-fast-path entries=62 saved=74
"""
assert preflight.readiness_markers_present(revision_fast_path)

activity_state = """ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
Display #0 (activities from top to bottom):
  * Task{abc #1 I=dev.zic.zic/.MainActivity visible=true}
    topResumedActivity=ActivityRecord{abc u0 dev.zic.zic/.MainActivity}
Display #53 (activities from top to bottom):
"""
assert preflight.activity_display(activity_state) == 0
assert preflight.input_command(0, "tap", "100", "200") == [
    "adb",
    "shell",
    "input",
    "-d",
    "0",
    "tap",
    "100",
    "200",
]

try:
    preflight.normalize_abi("unsupported")
except ValueError:
    pass
else:
    raise AssertionError("unsupported ABI must fail before installing an arbitrary APK")

print("Reader device preflight build/readiness/display contract: OK")
