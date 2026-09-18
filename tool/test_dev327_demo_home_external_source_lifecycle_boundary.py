#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(f"DemoHome external-source lifecycle boundary missing {label}: {marker}")


lifecycle = text("apps/app/lib/home_external_source_lifecycle.dart")
source_browser = text("apps/app/lib/source_browser.dart")
home_files = [
    "apps/app/lib/demo_home.dart",
    "apps/app/lib/demo_home_service_handoff.dart",
    "apps/app/lib/demo_home_source_compat.dart",
    "apps/app/lib/demo_home_views.dart",
]
home = "\n".join(text(path) for path in home_files)

require(lifecycle, "final class HomeExternalSourceLifecycle", "standalone lifecycle owner")
for marker, label in (
    ("Future<ExternalPluginController?> ensureController()", "controller single-flight"),
    ("Future<void> waitForSource(String sourceId)", "exact-source wait"),
    ("Future<void> refreshCurrentProjection()", "projection refresh single-flight"),
    ("Stream<void> get sourceProjectionChanges", "projection generation signal"),
    ("controller.sourceChanges.listen", "source-change observation"),
    ("Future<void> retryActivation(String pluginId)", "retry ownership"),
    ("Future<void>? _closing;", "joinable lifecycle close"),
    ("final refresh = _refresh;", "entered refresh drain"),
    ("await refresh;", "entered refresh completion"),
):
    require(lifecycle, marker, label)

for forbidden in (
    "part of 'demo_home.dart'",
    "_DemoHomeState",
    "BuildContext",
    "Navigator",
    "setState(",
    "State<",
    "StatefulWidget",
):
    if forbidden in lifecycle:
        raise SystemExit(
            f"HomeExternalSourceLifecycle leaked Home/UI ownership: {forbidden}"
        )

require(home, "late final HomeExternalSourceLifecycle _externalSources;", "Home lifecycle binding")
require(home, "_externalSources.adoptController(plugins);", "service handoff adoption")
require(home, "_externalSources.signalLoaderAvailable();", "loader handoff wake")
require(home, "_externalSources.waitForSource(", "source wait delegation")
require(
    home,
    "await _externalSources.close();\n    try {\n      await _librarySession.close();",
    "external refresh drain before Home session close",
)
if "unawaited(_externalSources.close());" in home:
    raise SystemExit(
        "DemoHome external-source lifecycle close must not race Home session close"
    )
require(home, "externalPlugins: _externalSources.activeController", "source page projection")
require(
    home,
    "externalSourceChanges: _externalSources.sourceProjectionChanges",
    "source-management projection generation binding",
)
require(
    home,
    "readExternalPlugins: () => _externalSources.activeController",
    "source-management current controller resolver",
)
require(
    home,
    "final initialExternalSourceIds = _sourceProjection.externalSourceIds;",
    "source-management projection-owned route seed identity",
)
require(
    home,
    "initialExternalSourceIds: initialExternalSourceIds",
    "source-management route seed binding",
)
for marker, label in (
    ("final Stream<void>? externalSourceChanges;", "management change signal"),
    ("final Set<String>? initialExternalSourceIds;", "management route seed identity"),
    ("final ExternalPluginController? Function()? readExternalPlugins;", "management controller resolver"),
    ("final List<BrowsableComicSource> Function()? readExternalSources;", "management source resolver"),
    ("_replaceExternalSources(_readExternalSources(), notify: false);", "management pre-listen reconcile"),
    ("_refreshExternalSources(_readExternalSources())", "management current-source refresh"),
):
    require(source_browser, marker, label)

for forbidden in (
    "HomeServiceHandoff",
    "HomeExternalSourceLifecycle",
):
    if forbidden in source_browser:
        raise SystemExit(
            f"SourceManagement leaked Home service/source-lifecycle ownership: {forbidden}"
        )

for forbidden in (
    "ExternalPluginController? _activeExternalPlugins",
    "ExternalPluginController? _watchedExternalPlugins",
    "StreamSubscription<void>? _externalPluginSourceChanges",
    "Completer<void>? _initialExternalSourcesPublished",
    "Future<ExternalPluginController?>? _externalPluginLoading",
    "Future<void>? _externalSourcesPublishing",
    "Future<void>? _externalSourceRefresh",
    "bool _externalSourceRefreshPending",
    "_watchExternalPluginSources(",
    "_requestExternalSourceRefresh(",
    "_drainExternalSourceRefresh(",
    "_ensureExternalPluginController(",
    "_waitForExternalSource(",
    ".sourceChanges.listen",
):
    if forbidden in home:
        raise SystemExit(
            f"DemoHome re-acquired external source lifecycle responsibility: {forbidden}"
        )

print("dev.327 DemoHome external source lifecycle boundary: OK")
