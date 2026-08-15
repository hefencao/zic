#!/usr/bin/env python3
"""Guard dev.292 resident replay service/capability binding and owner closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def text(path): return (ROOT / path).read_text(encoding="utf-8")
def req(ok, msg):
    if not ok: raise SystemExit(f"FAIL: {msg}")
def require(path, *markers):
    body = text(path)
    missing = [marker for marker in markers if marker not in body]
    req(not missing, f"{path} missing dev.292 contract: {missing}")

def forbid(path, *markers):
    body = text(path)
    present = [marker for marker in markers if marker in body]
    req(not present, f"{path} retains forbidden dev.292 coupling: {present}")

pub = text("apps/app/pubspec.yaml")
m = re.search(r"^version:\s+0\.31\.0\+(\d+)\s*$", pub, re.M)
req(m is not None and int(m.group(1)) >= 292, "dev.292 app version missing")

require(
    "packages/sessions/lib/src/download_session.dart",
    "typedef DownloadResidentReplayChunks = Future<Stream<List<int>>> Function(",
    "typedef DownloadResidentReplaySource = Future<Stream<List<int>>> Function(",
    "DownloadSession session,",
    "DownloadResidentReplayChunks? residentReplayChunks",
    "final chunks = await replay(end);",
)
forbid(
    "packages/sessions/lib/src/download_session.dart",
    "await replay(this, end)",
    "typedef DownloadIngressReplayChunks",
)
require(
    "packages/sessions/lib/src/download_ingress_registry.dart",
    "final DownloadResidentReplaySource? residentReplaySource;",
    "return replay(session, endExclusive);",
)
forbid(
    "packages/sessions/lib/src/download_ingress_registry.dart",
    "typedef ResidentIngressReplaySource",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_page_stream.dart",
    "DownloadResidentReplaySource? residentReplaySource",
    "residentReplayChunks: replaySource == null",
    "replaySource(session, endExclusive)",
)
require(
    "packages/downloads/lib/src/composition_download_transfer_runtime.dart",
    "DownloadResidentReplaySource residentReplaySource(",
    "await cache.lookup(session.id)",
    "owner.openResidentReplay(",
    "localReadScheduler.acquire(priority: priority)",
    "resident replay requires the current physical session",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_reader_session.dart",
    "_transferRuntime.residentReplaySource(",
    "residentReplaySource: _residentReplaySource",
)
forbid(
    "packages/pipeline_runtime/lib/src/pipeline_reader_session.dart",
    "Future<Stream<List<int>>> _openResidentReplaySource(",
    "_scheduledResidentReplay(",
    "_boundedResidentReplay(",
)
require(
    "packages/downloads/lib/src/promoted_artifact_cache_handoff.dart",
    "final DownloadResidentReplaySource? residentReplaySource;",
)
forbid(
    "packages/downloads/lib/src/promoted_artifact_cache_handoff.dart",
    "typedef ResidentArtifactReplaySource",
)
require(
    "packages/downloads/test/physical_transfer_retention_test.dart",
    "resident replay binds runtime service to one physical generation",
    "final replaySource = runtime.residentReplaySource(",
    "residentReplayChunks: (endExclusive) =>",
    "replaySource(session, endExclusive)",
)
for path in (
    "docs/adr/0271-resident-replay-service-binding-boundary.md",
    "docs/audits/dev292-resident-replay-binding-boundary-audit.md",
):
    req((ROOT / path).is_file(), f"missing dev.292 governance file: {path}")
require("docs/ARCHITECTURE.md", "DownloadResidentReplaySource", "DownloadResidentReplayChunks")
require("docs/SPEC.md", "DownloadResidentReplaySource", "CompositionDownloadTransferRuntime")
require("docs/IMPLEMENTATION_STATUS.md", "dev.292", "replay(this,end)")
require("docs/IMPLEMENTATION_PLAN.md", "dev.292", "Function(DownloadSession,int)")
require("docs/NEXT_CHAT_HANDOFF.md", "dev.292", "DownloadResidentReplayChunks")
require("CHANGELOG.md", "0.31.0-dev.292", "Resident replay service binding boundary")
req("test_dev292_resident_replay_binding_boundary.py" in text("tool/check.sh"),
    "dev.292 gate not wired into tool/check.sh")
print("PASS: dev.292 resident replay service/capability boundary")
