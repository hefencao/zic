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
    ("requiresSourceLocatorRefresh: (chapter) =>", "shared locator-validity capability"),
    ("scheduleMetadataTask: ({", "composition-owned metadata scheduler injection"),
    ("cancelQueuedMetadataTask: (key) =>", "queued metadata task cancellation injection"),
    ("cancelMetadataTask: (key) =>", "active metadata task cancellation injection"),
    ("await _versionReuseLifecycle.close();", "lifecycle teardown barrier"),
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
    ("final HomeVersionQueuedMetadataTaskCanceller cancelQueuedMetadataTask;", "queued task cancellation capability"),
    ("final HomeVersionMetadataTaskCanceller cancelMetadataTask;", "active task cancellation capability"),
    ("final Map<String, Future<void>> _warmups", "warmup coalescing state"),
    ("final Map<String, Future<void>> _readerRefreshes", "Reader refresh coalescing state"),
    ("final Set<Future<dynamic>> _activeOperations", "admitted operation drain"),
    ("Future<void> close()", "joinable lifecycle close"),
    ("cancelQueuedMetadataTask(entry.value)", "queued refresh teardown cancellation"),
    ("cancelMetadataTask(entry.value)", "active refresh teardown cancellation"),
    ("VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(", "bounded version-page proof"),
    ("session.upsertVersionRelationDerivedState(updatedRelation)", "derived relation persistence"),
    ("scheduleMetadataTask(", "shared NetLane scheduling capability"),
    ("!requiresSourceLocatorRefresh(existing.chapter)", "shared locator-validity rule"),
    ("Future<int> ensureAuthority(", "Reader version authority"),
    ("Future<HomeVersionState> loadVersionState(", "version-state load"),
    ("_storedVersionRelationsStable({", "stable relation-generation read"),
    ("if (!identical(session.library, libraryStore))", "in-flight library identity revalidation"),
    ("final provider = session.downloadComposition;", "session-normalized transfer capability"),
):
    require(owner, marker, label)

close_body = home[home.index("Future<void> _closeHomeComposition() async {"):]
for earlier, later, label in (
    ("_sourceMigrationRecovery,", "await _readerChapterComposition.close();", "migration recovery before Reader composition close"),
    ("await _readerChapterComposition.close();", "await _versionReuseLifecycle.close();", "Reader composition before version lifecycle close"),
    ("await _versionReuseLifecycle.close();", "await _externalSources.close();", "version lifecycle before external source close"),
    ("await _externalSources.close();", "await _librarySession.close();", "external source close before session close"),
):
    if close_body.index(earlier) > close_body.index(later):
        raise SystemExit(f"Home version lifecycle teardown ordering regressed: {label}")

for forbidden in (
    "package:flutter/",
    "BuildContext",
    "Navigator",
    "ScaffoldMessenger",
    "WidgetsBinding",
    "setState(",
    "_DemoHomeState",
    "ComicSourceResourceGateway",
    "HomeServiceHandoff",
    "libraryGenerationChanges",
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
