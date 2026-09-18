#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f"DemoHome source-migration transaction boundary missing {label}: {marker}"
        )


home = text("apps/app/lib/demo_home.dart")
ui = text("apps/app/lib/demo_home_source_migration.dart")
owner = text("apps/app/lib/home_source_migration_transaction.dart")

for marker, label in (
    ("late final HomeSourceMigrationTransaction _sourceMigrationTransaction;", "single transaction owner"),
    ("_sourceMigrationTransaction = HomeSourceMigrationTransaction(", "owner composition"),
    ("session: _librarySession,", "session authority"),
    ("ensureDurableLibrary: () async {", "durable library boundary"),
    ("await _serviceHandoff?.ensureCoreServices?.call();", "durable service open"),
    ("await _adoptDurableServices();", "durable service adoption"),
    ("artifactCache: () => _readerArtifactCache,", "generation cache capability"),
    ("verifiedPageReuseIdentity:", "narrow reuse capability"),
):
    require(home, marker, label)

for forbidden in (
    "Future<void>? _sourceMigrationRecovery;",
    "SourceMigrationJournalStore",
    "runSourceMigrationJournal(",
    "VerifiedArtifactReusePlan.match(",
    "_PreparedChapterMigration",
    "_sourceMigrationPreparedFingerprint",
    "_commitSourceMigrationCleanup",
):
    if forbidden in home or forbidden in ui:
        raise SystemExit(
            f"DemoHome re-acquired source-migration transaction authority: {forbidden}"
        )

for marker, label in (
    ("_sourceMigrationTransaction.resumeCommitted(migrationId)", "committed cleanup delegation"),
    ("_sourceMigrationTransaction.executeConfirmed(", "confirmed transaction delegation"),
    ("showSourceMigrationComparison(", "UI confirmation remains outside transaction"),
    ("_sourceMigrationResultSummaryMessages(", "UI result presentation"),
):
    require(ui, marker, label)

for marker, label in (
    ("final class HomeSourceMigrationTransaction", "transaction owner"),
    ("HomeMigrationDurableLibraryBoundary ensureDurableLibrary", "narrow durable boundary"),
    ("SourceMigrationJournalStore? _journalStore()", "journal capability"),
    ("Future<bool> recoverCommitted()", "recovery single-flight"),
    ("await ensureDurableLibrary();\n    final store = _journalStore();", "recovery/resume durable-before-journal order"),
    ("Future<bool> resumeCommitted(String migrationId)", "specific committed resume"),
    ("Future<HomeSourceMigrationResult> executeConfirmed({", "confirmed transaction"),
    ("VerifiedArtifactReusePlan.match(", "verified artifact reuse"),
    ("runSourceMigrationJournal(", "journal runner"),
    ("await session.upsertSavedComic(", "target metadata commit"),
    ("await session.upsertChapter(targetRecord);", "chapter metadata commit"),
    ("await session.persistProgress(", "progress migration"),
    ("await session.persistReadState(", "read-state migration"),
    ("await session.persistPreference(neutral);", "source preference cleanup"),
    ("await session.removeSavedComic(", "source cleanup"),
):
    require(owner, marker, label)

for forbidden in (
    "_library.saveComicPreference(",
    "_library.saveChapterReadState(",
    "session.replacePreference(",
    "session.replaceReadState(",
    "BuildContext",
    "Navigator",
    "ScaffoldMessenger",
    "showDialog",
    "setState(",
    "_DemoHomeState",
    "ComicSourceResourceGateway",
    "HomeServiceHandoff",
    "summaryMessages(",
    "漫画偏好已合并",
):
    if forbidden in owner:
        raise SystemExit(
            f"source-migration transaction owner leaked UI/broad composition dependency: {forbidden}"
        )

print("dev.331 DemoHome source migration transaction boundary: OK")
