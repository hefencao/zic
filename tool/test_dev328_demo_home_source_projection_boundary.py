#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f"DemoHome source-projection boundary missing {label}: {marker}"
        )


projection = text("apps/app/lib/home_source_projection.dart")
home_files = [
    "apps/app/lib/demo_home.dart",
    "apps/app/lib/demo_home_service_handoff.dart",
    "apps/app/lib/demo_home_catalog_identity.dart",
    "apps/app/lib/demo_home_source_compat.dart",
    "apps/app/lib/demo_home_source_migration.dart",
    "apps/app/lib/demo_home_reader_route.dart",
    "apps/app/lib/demo_home_views.dart",
]
home = "\n".join(text(path) for path in home_files)

require(projection, "final class HomeSourceProjection", "standalone projection owner")
for marker, label in (
    ("BrowsableComicSource? sourceForId(String sourceId)", "resolver projection"),
    ("List<BrowsableComicSource> composeForServices(", "service candidate projection"),
    ("void adoptServiceProjection(", "service adoption commit"),
    ("Future<void> refreshExternalSources(", "external source projection"),
    ("Future<bool> _persistKnownCanonicalComicIds()", "canonical identity persistence"),
    ("CachedBrowsableComicSource(", "shared response-cache decoration"),
):
    require(projection, marker, label)

for forbidden in (
    "part of 'demo_home.dart'",
    "_DemoHomeState",
    "BuildContext",
    "Navigator",
    "setState(",
    "State<",
    "StatefulWidget",
    "ExternalPluginController",
):
    if forbidden in projection:
        raise SystemExit(
            f"HomeSourceProjection leaked UI/plugin lifecycle ownership: {forbidden}"
        )

require(home, "late final HomeSourceProjection _sourceProjection;", "Home projection binding")
require(home, "sources: _sourceProjection.sources", "initial session source projection")
require(home, "_sourceProjection.composeForServices(", "durable handoff candidate projection")
require(home, "_sourceProjection.adoptServiceProjection(", "durable handoff projection commit")
require(home, "_sourceProjection.sourceForId(sourceId)", "source lookup delegation")
require(
    home,
    "_sourceProjection.refreshExternalSources(controller.activeSources)",
    "external lifecycle to projection handoff",
)

for forbidden in (
    "late List<BrowsableComicSource> _sources",
    "_buildCachedSources(",
    "_replaceExternalSourcesFor(",
    "_persistKnownCanonicalComicIds(",
):
    if forbidden in home:
        raise SystemExit(
            f"DemoHome re-acquired source projection responsibility: {forbidden}"
        )

print("dev.328 DemoHome source projection boundary: OK")
