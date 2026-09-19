#!/usr/bin/env python3
"""Guard Reader loading authority convergence after historical cache presentation."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.334 contract: {token}")


cache = read("packages/downloads/lib/src/artifact_cache_manager.dart")
handoff = read("packages/downloads/lib/src/partial_download_handoff.dart")
transport = read("packages/downloads/lib/src/artifact_cache_transport.dart")
composition = read(
    "packages/downloads/lib/src/composition_download_transfer_runtime.dart"
)
pipeline = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
progress = read("packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart")
check = read("tool/check.sh")

for token in (
    "_retainedHistoricalPresentationAuthorities",
    "readRetainedHistoricalPresentation(",
    "openRetainedHistoricalPresentationFile(",
    "hasRetainedHistoricalPresentation(",
    "if (!requiresFreshSource(id)) return null;",
    "clearRetainedHistoricalPresentation(",
):
    require(cache, token, "ArtifactCacheManager retained presentation authority")

for text, owner in (
    (handoff, "historical resident bind"),
    (transport, "historical transport fallback"),
):
    require(text, "storageId:", owner)
    require(text, "generation:", owner)
    require(text, "noteHistoricalCarrierServed(", owner)

require(
    composition,
    "reason != 'historical-carrier-stale-while-revalidate'",
    "destructive recovery boundary",
)

for token in (
    "cache.requiresFreshSource(id)",
    "openRetainedHistoricalPresentationFile(",
    "readRetainedHistoricalPresentation(",
    "_syncTransferProgressPresentationSatisfaction(",
    "_externalPresentationVisibleFrames.contains(identity)",
    "hasRetainedHistoricalPresentation(",
    "'retainedHistoricalPresentation': retainedHistoricalPresentation",
):
    require(pipeline, token, "Pipeline presentation continuity/progress boundary")

for token in (
    "setPresentationSatisfied(bool value)",
    "if (_presentationSatisfied)",
):
    require(progress, token, "Pipeline transfer progress projection")

for path, token in (
    (
        "packages/downloads/test/artifact_cache_manager_test.dart",
        "retained historical presentation survives fresh-source quarantine only for presentation",
    ),
    (
        "packages/downloads/test/partial_download_handoff_test.dart",
        "historical bind must preserve its exact selected storage generation for presentation continuity",
    ),
    (
        "packages/pipeline_runtime/test/presentation_local_direct_read_test.dart",
        "retained historical presentation remains readable through fresh-source quarantine",
    ),
    (
        "packages/pipeline_runtime/test/presentation_local_direct_read_test.dart",
        "retained historical presentation keeps progress suppressed across source epoch rebind",
    ),
    (
        "packages/pipeline_runtime/test/pipeline_transfer_progress_test.dart",
        "a satisfied current static presentation hides background transfer activity from the Reader loading projection",
    ),
):
    require(read(path), token, path)

require(check, "test_dev334_reader_loading_authority_convergence.py", "repository check")
print("dev.334 Reader loading authority convergence: OK")
