#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f"missing {label}: {token}")

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f"superseded {label}: {token}")

catalog = read("packages/catalog/lib/src/source_catalog.dart")
for token in (
    "this.discoveredAt,",
    "final DateTime? discoveredAt;",
    "Future<List<ComicVersionRelation>> listAllComicVersionRelations();",
):
    require(catalog, token, "durable version-relation projection contract")

session = read("apps/app/lib/home_library_session.dart")
for token in (
    "List<ComicVersionRelation> _versionRelations",
    "List<ComicVersionRelation> get versionRelations => _versionRelations;",
    "versionRelationStore.listAllComicVersionRelations,",
    "Future<void> upsertVersionRelation(ComicVersionRelation relation) async {",
    "replaceVersionRelation(relation);",
):
    require(session, token, "Home relation projection owner")

migration = read("apps/app/lib/demo_home_source_migration.dart")
for token in (
    "await _librarySession.upsertVersionRelation(",
    "DateTime? _projectedConfirmedSourceUpdateAt(",
    "_versionRelations",
    "Future<int> _restoreSourceVersionArtifactEquivalences(",
    "_sourceVersionRelationsForComic(",
    "findExistingReusableKeys(",
    "hasReusableEquivalentPhysicalState(",
    "artifactCache.linkEquivalent(",
    "VerifiedArtifactReusePlan.matchResolvedRelated(",
    "'stage': 'version-artifact-equivalence-restored'",
):
    require(migration, token, "version projection / bidirectional reuse composition")
forbid(
    migration,
    "if (relations.isEmpty) return 0;",
    "predecessor-only reuse early return",
)
for token in (
    "_reconcileConfirmedSourceUpdateSignal",
    "saved.copyWith(sourceUpdateAt: DateTime.now().toUtc())",
):
    forbid(migration, token, "version relation mirrored into chapter update signal")

views = read("apps/app/lib/demo_home_views.dart")
require(views, "_sourceUpdateAtForComic(comic) != null", "Home version update projection")

reuse = read("packages/downloads/lib/src/artifact_cache_reuse.dart")
for token in (
    "static Future<VerifiedArtifactReusePlan> matchResolvedRelated({",
    "required ChapterManifest sourceChapter,",
    "required ChapterManifest targetChapter,",
    "sourcePages.length - targetPages.length",
    "readerPageDownloadId(targetChapter, targetPages[targetIndex])",
    "int registerEquivalences(ArtifactCacheManager cache) {",
    "cache.linkEquivalent(first: entry.key, second: entry.value);",
):
    require(reuse, token, "symmetric acyclic artifact alias contract")

reuse_test = read("packages/downloads/test/artifact_cache_reuse_test.dart")
require(
    reuse_test,
    "resolved related reuse is bidirectional across an inserted page",
    "bidirectional reuse regression coverage",
)
version = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", read("apps/app/pubspec.yaml"), re.M)
if version is None or int(version.group(1)) < 208:
    raise SystemExit("App build must be at least 208")
if int(version.group(1)) >= 230:
    require(
        reuse_test,
        "reverse proof registration reuses one symmetric equivalence edge",
        "bidirectional equivalence regression coverage",
    )
else:
    require(
        reuse_test,
        "reverse reuse never creates an alias cycle",
        "bidirectional alias regression coverage",
    )

storage = read("packages/storage/lib/src/sqlite_imported_library_store.dart")
for token in (
    "Future<List<ComicVersionRelation>> listAllComicVersionRelations() async {",
    "predecessor_title, discovered_us",
    "relation.discoveredAt ?? DateTime.now().toUtc()",
):
    require(storage, token, "SQLite relation projection")
forbid(storage, "discovered_us = excluded.discovered_us", "relation rediscovery timestamp churn")

check = read("tool/check.sh")
require(check, "test_dev208_version_relation_projection_bidirectional_reuse.py", "release gate wiring")

android = re.search(r"^versionCode=(\d+)\s*$", read("apps/app/android/zic-version.properties"), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit("Android versionCode must match App build")

print("dev.208 version relation projection / bidirectional reuse: OK")
