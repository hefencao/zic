#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(f"demo-home reader composition boundary missing {label}: {marker}")


composition = text("apps/app/lib/home_reader_composition.dart")
home = text("apps/app/lib/demo_home.dart")
route = text("apps/app/lib/demo_home_reader_route.dart")

require(
    composition,
    "final class HomeReaderChapterComposition",
    "standalone chapter composition owner",
)
require(composition, "HomeReaderEntryHydrator", "narrow hydrate capability")
require(composition, "ComicSourceResourceGateway", "source response capability owner")
require(
    composition,
    "ChapterDownloadTransferRuntimeProvider? Function()",
    "dynamic transfer-runtime capability provider",
)
require(composition, "Future<HomeReaderPreparedChapter> prepare(", "prepare API")
require(
    composition,
    "Map<String, LocalImageResponseSource> responseSourcesFor(",
    "response projection API",
)

for forbidden in (
    "part of 'demo_home.dart'",
    "_DemoHomeState",
    "BuildContext",
    "Navigator",
    "setState(",
    "State<",
    "StatefulWidget",
):
    if forbidden in composition:
        raise SystemExit(
            f"standalone HomeReaderChapterComposition leaked Home/UI ownership: {forbidden}"
        )

require(home, "late final HomeReaderChapterComposition _readerChapterComposition;", "Home-owned collaborator")
require(home, "hydrateEntry:", "explicit Home session hydrate handoff")
require(home, "prepareVersionAuthority: _prepareReaderVersionAuthority", "version authority callback")
require(
    route,
    "_readerChapterComposition.prepare(",
    "Reader route delegation to composition owner",
)
require(
    route,
    "_readerChapterComposition.responseSourcesFor(",
    "generation recovery response delegation",
)
for forbidden in (
    "Future<_PreparedImportedChapter> _prepareImportedChapter(",
    "Map<String, LocalImageResponseSource> _readerResponseSourcesFor(",
):
    if forbidden in route:
        raise SystemExit(
            f"DemoHome route re-acquired chapter preparation responsibility: {forbidden}"
        )

print("dev.326 DemoHome reader chapter composition boundary: OK")
