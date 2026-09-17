#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f"DemoHome version-reuse lifecycle boundary missing {label}: {marker}"
        )


home = text("apps/app/lib/demo_home.dart")
ui = text("apps/app/lib/demo_home_source_migration.dart")
owner = text("apps/app/lib/home_version_reuse_lifecycle.dart")

for marker, label in (
    ("late final HomeVersionReuseLifecycle _versionReuseLifecycle;", "single lifecycle owner"),
    ("_versionReuseLifecycle = HomeVersionReuseLifecycle(", "owner composition"),
    ("session: _librarySession,", "session generation authority"),
    ("loadRemoteEntrySnapshot:", "fresh metadata capability"),
    ("verifiedPageReuseIdentity:", "verified page identity capability"),
    ("requiresSourceLocatorRefresh: chapterRequiresSourceLocatorRefresh,", "shared locator-validity capability"),
    ("scheduleMetadataTask: ({", "composition-owned metadata scheduler injection"),
):
    require(home, marker, label)

for forbidden in (
    "_versionReuseAuthorityStates",
    "_versionReuseWarmups",
    "_readerVersionRefreshes",
    "_warmVersionRelationPageMappings",
    "_runReaderMetadataVersionRefresh",
    "VerifiedArtifactReusePlan.matchResolvedRelatedIntervals",
):
    if forbidden in home or forbidden in ui:
        raise SystemExit(
            f"DemoHome re-acquired version-reuse lifecycle authority: {forbidden}"
        )

for marker, label in (
    ("final class HomeVersionReuseLifecycle", "lifecycle owner"),
    ("final class HomeVersionState", "composition-neutral version state"),
    ("final HomeLibrarySession session;", "dynamic session authority"),
    ("final HomeVersionMetadataTaskScheduler scheduleMetadataTask;", "injected metadata scheduling capability"),
    ("final Map<String, Future<void>> _warmups", "warmup coalescing state"),
    ("final Map<String, Future<void>> _readerRefreshes", "Reader refresh coalescing state"),
    ("VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(", "bounded version-page proof"),
    ("session.upsertVersionRelationDerivedState(updatedRelation)", "derived relation persistence"),
    ("scheduleMetadataTask(", "shared NetLane scheduling capability"),
    ("!requiresSourceLocatorRefresh(existing.chapter)", "shared locator-validity rule"),
    ("Future<int> ensureAuthority(", "Reader version authority"),
    ("Future<HomeVersionState> loadVersionState(", "version-state load"),
    ("final provider = session.downloadComposition;", "session-normalized transfer capability"),
):
    require(owner, marker, label)

for forbidden in (
    "package:flutter/",
    "BuildContext",
    "Navigator",
    "ScaffoldMessenger",
    "WidgetsBinding",
    "setState(",
    "_DemoHomeState",
    "ComicSourceResourceGateway",
    "comic_details.dart",
    "details.ComicDetailsVersionState",
    "local_media_composition.dart",
    "defaultDownloadResourceCoordinator",
    "source_resource_gateway.dart",
    "isLegacyVeneraRuntimeLocator",
    "downloads is ChapterDownloadTransferRuntimeProvider",
    "downloads as ChapterDownloadTransferRuntimeProvider",
    "_authorityStates",
    "relationFingerprintParts",
):
    if forbidden in owner:
        raise SystemExit(
            f"version-reuse lifecycle owner leaked UI/broad composition dependency: {forbidden}"
        )

for marker, label in (
    ("_versionReuseLifecycle.prepareWarmup(", "UI warmup delegation"),
    ("_versionReuseLifecycle.scheduleReaderMetadataVersionRefresh(", "Reader refresh delegation"),
    ("_versionReuseLifecycle.ensureAuthority(current)", "Reader authority delegation"),
    ("_versionReuseLifecycle.loadVersionState(", "version-state delegation"),
    ("details.ComicDetailsVersionState _detailsVersionState(", "UI version-state adapter"),
    ("_versionViewReusePreparations", "route-local view preparation stays in UI"),
):
    require(ui if marker != "_versionViewReusePreparations" else home, marker, label)

print("dev.332 DemoHome version reuse lifecycle boundary: OK")
