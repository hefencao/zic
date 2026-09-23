#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f"dev.335 HomeShell route-admission boundary missing {label}: {marker}"
        )


admission = text("apps/app/lib/home_route_admission.dart")
home = "\n".join(
    text(path)
    for path in (
        "apps/app/lib/home_shell.dart",
        "apps/app/lib/home_shell_reader_route.dart",
        "apps/app/lib/home_shell_source_compat.dart",
    )
)

for marker, label in (
    ("final class HomeRouteAdmission", "standalone route admission owner"),
    ("void beginReaderRoute()", "Reader coverage admission"),
    ("bool endReaderRoute()", "Reader coverage release"),
    ("bool tryBeginDownloadManagerRoute()", "download-manager single slot"),
    ("bool tryBeginComicRoute(String identity)", "identity-local comic admission"),
    ("bool endComicRoute(String identity)", "identity-local comic release"),
):
    require(admission, marker, label)

for forbidden in (
    "part of 'home_shell.dart'",
    "BuildContext",
    "Navigator",
    "State<",
    "StatefulWidget",
    "setState(",
    "HomeLibrarySession",
    "HomeServiceHandoff",
    "HomeDownloadCommands",
    "HomeVersionReuseLifecycle",
    "BrowsableComicSource",
    "ResourceCacheCoordinator",
):
    if forbidden in admission:
        raise SystemExit(
            f"HomeRouteAdmission leaked navigation/UI/subsystem authority: {forbidden}"
        )

for marker, label in (
    ("final HomeRouteAdmission _routeAdmission = HomeRouteAdmission();", "Home route admission binding"),
    ("_routeAdmission.readerRouteOpen", "Reader-covered Home rebuild suppression"),
    ("_routeAdmission.beginReaderRoute();", "Reader route admission delegation"),
    ("_routeAdmission.endReaderRoute();", "Reader route release delegation"),
    ("_setState(() {});", "Reader close presentation refresh"),
    ("_routeAdmission.tryBeginDownloadManagerRoute()", "download-manager admission delegation"),
    ("_routeAdmission.endDownloadManagerRoute();", "download-manager release delegation"),
    ("_routeAdmission.tryBeginComicRoute(", "comic route admission delegation"),
    ("_routeAdmission.endComicRoute(", "comic route release delegation"),
):
    require(home, marker, label)

for forbidden in (
    "bool _readerRouteOpen",
    "bool _downloadManagerRouteOpen",
    "_openingComicIdentities",
):
    if forbidden in home:
        raise SystemExit(
            f"HomeShell retained parallel route admission state: {forbidden}"
        )

print("dev.335 HomeShell route admission boundary: OK")
