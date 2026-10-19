#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


migration = read("apps/app/lib/home_shell_source_migration.dart")
version_lifecycle = read("apps/app/lib/home_version_reuse_lifecycle.dart")
home_session = read("apps/app/lib/home_library_session.dart")
if "_reconcileConfirmedSourceUpdateSignal" in migration:
    raise SystemExit(
        "removed version-to-sourceUpdateAt reconcile symbol still referenced in migration path"
    )

for token in (
    "final stored = await _storedVersionRelationsStable(",
    "final storedSuccessors = stored.successors;",
    "final storedPredecessors = stored.predecessors;",
    "await _rememberSourceVersions(",
    "await session.upsertVersionRelation(",
):
    if token not in version_lifecycle:
        raise SystemExit(f"missing current version relation owner contract: {token}")
for token in (
    "Future<ImportedLibraryStore> _persistVersionRelation(",
    "final persistedLibrary = await _persistVersionRelation(relation);",
    "if (!identical(library, persistedLibrary))",
    "final libraryStore = library;",
    "await store.saveComicVersionRelation(relation);",
    "await _serviceAdoption;",
    "if (identical(library, libraryStore))",
):
    if token not in home_session:
        raise SystemExit(f"missing stable version relation persistence contract: {token}")
if "saveComicVersionRelation(" in version_lifecycle:
    raise SystemExit("version lifecycle bypasses HomeLibrarySession relation persistence")
if "DateTime? _projectedConfirmedSourceUpdateAt(" not in migration:
    raise SystemExit("missing current source-update projection contract")

# Do not reintroduce the dev.207 mirror from confirmed version relation into the
# chapter/directory update signal. Chapter sourceUpdateAt writes elsewhere are
# still valid and are intentionally not prohibited globally.
if "saved.copyWith(sourceUpdateAt: DateTime.now().toUtc())" in migration:
    raise SystemExit("migration path mirrors version relation into sourceUpdateAt")

check = read("tool/check.sh")
if "test_dev209_removed_version_signal_call_closure.py" not in check:
    raise SystemExit("dev.209 closure gate is not wired into tool/check.sh")

version = re.search(
    r"^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$",
    read("apps/app/pubspec.yaml"),
    re.M,
)
if version is None or int(version.group(1)) < 209:
    raise SystemExit("App build must be at least 209")
android = re.search(
    r"^versionCode=(\d+)\s*$",
    read("apps/app/android/zic-version.properties"),
    re.M,
)
if android is None or android.group(1) != version.group(1):
    raise SystemExit("Android versionCode must match App build")

print("dev.209 removed version-signal call closure: OK")
