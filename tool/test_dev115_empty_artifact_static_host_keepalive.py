#!/usr/bin/env python3
"""Guard dev.115 empty-artifact self-heal and static host retention."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.115 contract: {token}")

manager = read("packages/downloads/lib/src/artifact_cache_manager.dart")
store = read("packages/downloads/lib/src/artifact_cache_store.dart")
chapter = read("packages/downloads/lib/src/chapter_downloads.dart")
handoff = read("packages/downloads/lib/src/promoted_artifact_cache_handoff.dart")
download = read("packages/sessions/lib/src/download_session.dart")
job = read("packages/sessions/lib/src/download_job.dart")
reader = read("packages/reader/lib/src/reader_view.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

require(
    store,
    "Future<void> invalidateArtifact(DownloadId id)",
    "cache backend invalidation primitive",
)
if "ArtifactCacheInvalidationBackend" in store:
    raise SystemExit("cache invalidation remains an unnecessary optional capability")
for token in (
    "if (bytes.isEmpty)",
    "await invalidate(id)",
    "cannot store an empty promoted artifact",
    "artifact cache body is empty",
):
    require(manager, token, "central artifact cache manager")
for token in (
    "record.bytes <= 0",
    "length <= 0 || length != record.bytes",
    "_invalidateIndexedArtifact",
    "cannot cache an empty Reader artifact",
):
    require(chapter, token, "chapter artifact backends")
for token in (
    "session.residentCacheBacked",
    "skip-cache-resident",
    "skip-empty",
):
    require(handoff, token, "promoted artifact handoff")
for token in (
    "totalLength <= 0",
    "durable cache source has no recognizable image body",
):
    require(download, token, "durable cached ingress")
for token in (
    "image response body is empty",
    "image response produced no bytes",
):
    require(job, token, "download response admission")
for token in (
    "AutomaticKeepAliveClientMixin<_ReaderPageHost>",
    "bool get wantKeepAlive => widget.keepAlive",
    "(index - widget.controller.currentIndex).abs() <= 7",
):
    require(reader, token, "vertical static page host")
if reader.count("TraceEventKind kind, {") != 1:
    raise SystemExit("Reader lifecycle callback contains a duplicate kind declaration")
for token in (
    "emptyArtifactEventCount",
    "emptyArtifactHandoffStoreCount",
):
    require(analyzer, token, "trace analyzer empty-artifact diagnostics")
for path, token in (
    (
        "packages/downloads/test/artifact_cache_manager_test.dart",
        "purges an empty memory/backend artifact instead of serving it",
    ),
    (
        "packages/downloads/test/promoted_artifact_cache_handoff_test.dart",
        "cache-resident promoted sessions never write empty artifacts back",
    ),
    (
        "packages/sessions/test/download_job_test.dart",
        "rejects an unknown-length stream that produces no bytes",
    ),
):
    require(read(path), token, path)
require(check, "test_dev115_empty_artifact_static_host_keepalive.py", "repository check")
print("dev.115 empty artifact/static host keepalive contract: OK")
