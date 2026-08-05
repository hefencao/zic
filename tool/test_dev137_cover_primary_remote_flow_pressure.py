#!/usr/bin/env python3
"""Guard dev.137 progressive cover publication and current-source flow pressure."""
from pathlib import Path
import json
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.137 contract: {token}")

home = read("apps/app/lib/home_library_session.dart")
home_test = read("apps/app/test/home_library_session_test.dart")
job = read("packages/sessions/lib/src/download_job.dart")
job_test = read("packages/sessions/test/download_job_test.dart")
gate = read("packages/sessions/lib/src/net_lane.dart")
gate_test = read("packages/sessions/test/net_lane_test.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
trace = read("packages/telemetry/lib/src/trace.dart")
profile = read("packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

for token in (
    "final entriesFuture = library.list()",
    "final savedComicsFuture = library.listSavedComics()",
    "if (publishPrimary)",
    "_savedComics = List<SavedComicRecord>.unmodifiable(savedComics)",
    "'home-library-primary'",
    "final categoriesFuture = library.listCategories()",
    "final readStatesFuture = library.listAllChapterReadStates()",
):
    require(home, token, "Home primary projection")
primary_publish = home.index("if (publishPrimary)")
enrichment_wait = home.index("final categories = await categoriesFuture")
if primary_publish >= enrichment_wait:
    raise SystemExit("cover-bearing primary projection must publish before enrichment")
require(
    home_test,
    "publishes cover-bearing primary library before enrichment finishes",
    "Home owner test",
)

for token in (
    "typedef DownloadChunkPermit",
    "final pending = BytesBuilder(copy: false)",
    "var flushTarget = 16 * 1024",
    "flushTarget = sourceProgressQuantumBytes",
    "await beforeReadChunk?.call(cancel)",
    "Preserve bytes already delivered by the transport",
):
    require(job, token, "DownloadJob coalescing")
require(
    job_test,
    "coalesces tiny transport chunks before native/artifact ingress",
    "DownloadJob owner test",
)

for token in (
    "final class DownloadFlowGate",
    "Future<void> wait(",
    "_foregroundKey != key",
    "_bucket == bucket",
):
    require(gate, token, "cooperative flow gate")
for token in (
    "foreground flow gate pauses only same-bucket background pulls",
    "foreground flow gate cancellation does not wait for release",
):
    require(gate_test, token, "flow gate owner test")

for token in (
    "DownloadFlowGate? downloadFlowGate",
    "_refreshDownloadFlowPressure(sessionId)",
    "TraceEventKind.downloadFlowPressure",
    "beforeReadChunk: (cancel) => downloadFlowGate.wait(",
    "entry.value.role == PageRole.current",
):
    require(coordinator, token, "LiveCoordinator foreground flow ownership")
for forbidden in (
    "networkConcurrency: 1",
    "remoteSourceConcurrency: 1",
    "forwardEncodedPages: 1",
    "backwardEncodedPages: 0",
):
    if forbidden in profile:
        raise SystemExit(f"stable window/lane was improperly reduced: {forbidden}")
for token in (
    "forwardEncodedPages: 7",
    "backwardEncodedPages: 3",
    "networkConcurrency: 5",
    "decodeConcurrency: 3",
    "uploadConcurrency: 2",
    "remoteSourceConcurrency: 5",
):
    require(profile, token, "stable Reader profile")

require(trace, "downloadFlowPressure", "Trace event schema")
for token in (
    '"homeFirstCoverRequestMicros"',
    '"downloadFlowPressureHoldCount"',
    '"downloadFlowPressureReleaseCount"',
):
    require(analyzer, token, "Trace analyzer")
require(check, "test_dev137_cover_primary_remote_flow_pressure.py", "repository check")

# Exercise the analyzer's new keys on a minimal fixture.
import importlib.util
spec = importlib.util.spec_from_file_location(
    "frame_trace_analyzer", ROOT / "tool/analyze_frame_pipeline_trace.py"
)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as tmp:
    fixture = Path(tmp) / "trace.jsonl"
    fixture.write_text(
        "\n".join(
            json.dumps(row)
            for row in (
                {
                    "t": 10,
                    "sessionId": "home-startup",
                    "kind": "homeServiceReady",
                    "payload": {"stage": "home-library-primary", "durationMicros": 8},
                },
                {
                    "t": 12,
                    "sessionId": "home-startup",
                    "kind": "homeCoverRequested",
                    "identityHash": "cover",
                },
                {
                    "t": 20,
                    "sessionId": "reader",
                    "kind": "downloadFlowPressure",
                    "identityHash": "current",
                    "payload": {"state": "hold", "bucket": "remote:s"},
                },
                {
                    "t": 30,
                    "sessionId": "reader",
                    "kind": "downloadFlowPressure",
                    "identityHash": "current",
                    "payload": {"state": "release", "bucket": "remote:s"},
                },
            )
        )
        + "\n",
        encoding="utf-8",
    )
    report = module.summarize(fixture)
    assert report["homeFirstCoverRequestMicros"] == 12
    assert report["downloadFlowPressureHoldCount"] == 1
    assert report["downloadFlowPressureReleaseCount"] == 1

print("dev.137 cover primary / remote flow-pressure contract: OK")
