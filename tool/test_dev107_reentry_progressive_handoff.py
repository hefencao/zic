#!/usr/bin/env python3
"""Guard dev.107 Reader reentry cleanup and progressive foreground ingress."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.107 contract: {token}")


store = read("packages/downloads/lib/src/artifact_cache_store.dart")
chapter = read("packages/downloads/lib/src/chapter_downloads.dart")
handoff = read("packages/downloads/lib/src/promoted_artifact_cache_handoff.dart")
transport = read("packages/downloads/lib/src/artifact_cache_transport.dart")
pipeline = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
handoff_test = read("packages/downloads/test/promoted_artifact_cache_handoff_test.dart")
transport_test = read("packages/downloads/test/artifact_cache_transport_test.dart")
check = read("tool/check.sh")
pubspec = read("apps/app/pubspec.yaml")

for token in (
    "abstract interface class ArtifactCachePresenceStore",
    "Future<bool> containsPromotedArtifact",
    "required int expectedLength",
):
    require(store, token, "artifact cache presence capability")

require(chapter, "ArtifactCachePresenceStore", "chapter artifact cache")
if chapter.count("Future<bool> containsPromotedArtifact") < 2:
    raise SystemExit("memory and persistent chapter caches must both probe presence")

for token in (
    "presence.containsPromotedArtifact",
    "action: 'skip-existing'",
    "source': 'session-artifact-handoff'",
    "final builder = BytesBuilder(copy: false);",
):
    require(handoff, token, "promoted artifact handoff")
if handoff.index("presence.containsPromotedArtifact") > handoff.index(
    "final builder = BytesBuilder(copy: false);"
):
    raise SystemExit("persistent presence must be checked before session bytes materialize")

for token in (
    "foregroundStartupSegmented: true",
    "deliveryMode': 'startup-segmented'",
    "Stream<List<int>> _startupSegmentedBytes",
    "await Future<void>.delayed(Duration.zero);",
    "readScheduler?.foregroundPressureHoldCount ?? 0",
):
    require(transport, token, "artifact cache transport")
if "wholeBodyChunk: true" in transport or "deliveryMode': 'whole-body'" in transport:
    raise SystemExit("foreground cache hits must not return one blocking whole-body chunk")

for token in (
    "_artifactCacheHandoff?.detach();",
    "'coordinatorDisposeMicros': coordinatorDisposeMicros",
    "'handoffDrainMicros': handoffDrainMicros",
    "'workspaceDisposeMicros': workspaceDisposeMicros",
):
    require(pipeline, token, "Reader session disposal")
if pipeline.index("_artifactCacheHandoff?.detach();") > pipeline.index(
    "await _coordinator.dispose();"
):
    raise SystemExit("cache handoff listeners must detach before coordinator shutdown")

require(
    handoff_test,
    "skips materializing a session artifact already present durably",
    "handoff owner test",
)
require(
    transport_test,
    "foreground read-all holds its scheduler lease until body drains",
    "transport owner test",
)
require(check, "test_dev107_reentry_progressive_handoff.py", "repository check")
require(pubspec, "version: 0.31.0+107", "app version")

for path in (
    "docs/adr/0091-reader-reentry-progressive-artifact-handoff.md",
    "docs/audits/dev107-reentry-progressive-handoff-audit.md",
    "docs/audits/dev107-validation-results.md",
):
    if not (ROOT / path).is_file():
        raise SystemExit(f"dev.107 evidence is missing: {path}")

print("dev.107 reentry progressive handoff: OK")
