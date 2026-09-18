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
    ("Set<String> get externalSourceIds", "read-only external-source identity projection"),
    ("Set<String> _externalSourceIds", "explicit external-source ownership"),
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
    "startsWith('mihon:')",
    "startsWith('venera:')",
):
    if forbidden in projection:
        raise SystemExit(
            f"HomeSourceProjection leaked UI/plugin lifecycle ownership: {forbidden}"
        )

require(home, "late final HomeSourceProjection _sourceProjection;", "Home projection binding")
require(home, "sources: _sourceProjection.sources", "initial session source projection")
require(home, "_sourceProjection.composeForServices(", "durable handoff candidate projection")
require(home, "_sourceProjection.adoptServiceProjection(", "durable handoff projection commit")
require(home, "externalSources: activeExternalSources,", "durable external identity handoff")
require(home, "_sourceProjection.sourceForId(sourceId)", "source lookup delegation")
require(
    home,
    "_sourceProjection.refreshExternalSources(controller.activeSources)",
    "external lifecycle to projection handoff",
)
require(
    home,
    "final initialExternalSourceIds = _sourceProjection.externalSourceIds;",
    "source-management projection-owned external identity seed",
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

source_management = text("apps/app/lib/source_browser.dart")
require(
    source_management,
    "Set<String> _externalSourceIds = <String>{};",
    "source-management explicit external-source ownership",
)
refresh_start = source_management.index(
    "  void _replaceExternalSources("
)
refresh_end = source_management.index(
    "  Future<void> _openSourceSettings", refresh_start
)
refresh_body = source_management[refresh_start:refresh_end]
for marker, label in (
    ("final nextExternalSourceIds = <String>{", "next external identity set"),
    ("..._externalSourceIds,", "previous external identity set"),
    ("!replacedSourceIds.contains(source.sourceId)", "identity-based replacement"),
    ("_externalSourceIds = nextExternalSourceIds;", "external identity generation commit"),
):
    require(refresh_body, marker, label)
for forbidden in ("startsWith('mihon:')", "startsWith('venera:')"):
    if forbidden in refresh_body:
        raise SystemExit(
            f"SourceManagementScreen inferred external ownership from sourceId prefix: {forbidden}"
        )

print("dev.328 DemoHome source projection boundary: OK")
