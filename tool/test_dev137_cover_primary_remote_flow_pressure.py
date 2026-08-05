#!/usr/bin/env python3
"""Guard dev.137 cover publication while rejecting its superseded flow gate."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing retained dev.137 contract: {token}")


home = read("apps/app/lib/home_library_session.dart")
home_test = read("apps/app/test/home_library_session_test.dart")
job = read("packages/sessions/lib/src/download_job.dart")
job_test = read("packages/sessions/test/download_job_test.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
net_lane = read("packages/sessions/lib/src/net_lane.dart")
trace = read("packages/telemetry/lib/src/trace.dart")
profile = read("packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")

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
if home.index("if (publishPrimary)") >= home.index(
    "final categories = await categoriesFuture"
):
    raise SystemExit("cover-bearing primary projection must publish before enrichment")
require(
    home_test,
    "publishes cover-bearing primary library before enrichment finishes",
    "Home owner test",
)

for token in (
    "final pending = BytesBuilder(copy: false)",
    "var flushTarget = 16 * 1024",
    "flushTarget = sourceProgressQuantumBytes",
    "Preserve bytes already delivered by the transport",
):
    require(job, token, "DownloadJob coalescing")
require(
    job_test,
    "coalesces tiny transport chunks before native/artifact ingress",
    "DownloadJob owner test",
)

# ADR 0121/dev.138 supersedes the global same-bucket flow gate. Current is
# protected by NetLane reservation/preemption; target-page reads stay independent.
for production in (job, coordinator, net_lane, trace):
    for forbidden in (
        "DownloadFlowGate",
        "beforeReadChunk",
        "downloadFlowPressure",
        "_refreshDownloadFlowPressure",
    ):
        if forbidden in production:
            raise SystemExit(f"superseded dev.137 flow gate remains: {forbidden}")

for token in (
    "forwardEncodedPages: 7",
    "backwardEncodedPages: 3",
    "networkConcurrency: 5",
    "decodeConcurrency: 3",
    "uploadConcurrency: 2",
    "remoteSourceConcurrency: 5",
):
    require(profile, token, "stable Reader profile")
require(analyzer, '"homeFirstCoverRequestMicros"', "Trace analyzer")

print("dev.137 retained cover/coalescing contracts; flow gate superseded: OK")
