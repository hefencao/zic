#!/usr/bin/env python3
"""Guard Reader first-frame optimizations from becoming lifecycle authorities."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


route = read("apps/app/lib/demo_home_reader_route.dart")
pipeline = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
scheduler = read("packages/downloads/lib/src/artifact_cache_read_scheduler.dart")

if "final mediaPrewarm = prewarmDefaultLocalMediaPipeline();" not in route:
    raise SystemExit("Reader media prewarm trigger is missing")
if "unawaited(" not in route or "mediaPrewarm.catchError" not in route:
    raise SystemExit("Reader media prewarm must be acceleration-only and observed in background")
if "await mediaPrewarm" in route:
    raise SystemExit("Reader chapter preparation must never await speculative media prewarm")

for forbidden in (
    "_startupCurrentDownload",
    "_startupArtifactPressure",
    "artifactReadScheduler.holdForegroundPressure(",
):
    if forbidden in pipeline:
        raise SystemExit(f"first-output lifecycle leaked into scheduler policy: {forbidden}")
if "downloadBucketLimitFor: _profile.downloadBucketLimit" not in pipeline:
    raise SystemExit("Reader must submit the stable profile bucket policy to NetLane")
if "reserveFirstForegroundQuantum" in scheduler:
    raise SystemExit("local-read scheduler must not reserve a global first-frame quantum")

print("Reader first-frame ownership decoupling: OK")
