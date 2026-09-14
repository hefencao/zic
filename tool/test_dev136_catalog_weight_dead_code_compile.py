#!/usr/bin/env python3
"""Guard dev.136 metadata weight and dead compatibility cleanup."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.136 contract: {token}")


catalog = read("packages/catalog/lib/src/cached_comic_source.dart")
catalog_test = read("packages/catalog/test/cached_comic_source_test.dart")
handoff = read("packages/downloads/lib/src/promoted_artifact_cache_handoff.dart")
cold_test = read("apps/app/test/reader_artifact_cold_open_test.dart")
local_models = read("packages/local_media_ui/lib/src/models_and_preview.dart")
local_screens = read("packages/local_media_ui/lib/src/local_media_screens.dart")
local_player = read("packages/local_media_ui/lib/src/native_webp_player.dart")
demo_home = read("apps/app/lib/demo_home.dart")
check = read("tool/check.sh")
app_pubspec = read("apps/app/pubspec.yaml")
android_version = read("apps/app/android/zic-version.properties")

for token in (
    "int _browseWeight(SourceBrowsePage page)",
    "int _comicWeight(ComicManifest manifest)",
    "int _chapterWeight(ChapterManifest manifest)",
    "_cacheCollectionWeight<SourceComicSummary>",
    "_cacheCollectionWeight<PageAsset>",
    "value.length * 2",
):
    require(catalog, token, "catalog metadata weight")
for forbidden in (
    "weightOf: (_) => 1",
    "jsonEncode(",
):
    if forbidden in catalog:
        raise SystemExit(f"catalog weight must not use placeholder allocation: {forbidden}")
for token in (
    "ResourceCacheKind.comicDetails).weight",
    "ResourceCacheKind.chapterMetadata).weight",
    "ResourceCacheKind.searchResults).weight",
):
    require(catalog_test, token, "catalog owner test")

for token in (
    "Future<void> _runCommit(DownloadSession session) async",
    "final target = defaultTarget?.call(session) ?? session.id;",
    "await _commitTarget(session, target);",
    "requireExactDurableBody: true",
    "_commits.remove(id)",
):
    require(handoff, token, "artifact handoff task")
if ".catchError(" in handoff:
    raise SystemExit("artifact handoff must not retain the runtime-invalid catchError handler")
require(cold_test, "Future<void> invalidateArtifact(DownloadId id)", "cold Reader backend")

for forbidden in (
    "typedef WebpFolderPicker =",
    "typedef WebpLoadToken =",
    "final class PickedWebpFolder",
    "const webpFolderScreenKey =",
    "pickLocalWebpFolder(",
    "defaultWebpFolderPicker(",
):
    if forbidden in local_models:
        raise SystemExit(f"dead local-media compatibility remains: {forbidden}")
if "final class WebpFolderScreen" in local_screens:
    raise SystemExit("dead WebpFolderScreen wrapper remains")
for token in (
    "typedef WebpBytesLoader = Future<Uint8List> Function(MediaLoadToken token)",
    "late final MediaLoadToken _loadToken",
    "_loadToken = MediaLoadToken()",
):
    if token not in local_models and token not in local_player:
        raise SystemExit(f"modern media token migration missing: {token}")
for forbidden in (
    "localWebpFolderImportKey",
    "localWebpFolderPickerProgressKey",
):
    if forbidden in demo_home:
        raise SystemExit(f"dead App key alias remains: {forbidden}")
if (ROOT / "apps/app/lib/local_webp_folder.dart").exists():
    raise SystemExit("dead App local_webp_folder facade remains")
if (ROOT / "apps/app/lib/local_image_folder.dart").exists():
    raise SystemExit("dead App local_image_folder facade remains")

app_match = re.search(r"^version: 0\.31\.0\+(\d+)$", app_pubspec, re.MULTILINE)
if app_match is None or int(app_match.group(1)) < 136:
    raise SystemExit("dev.136+ app version contract is missing")
android_match = re.search(r"^versionCode=(\d+)$", android_version, re.MULTILINE)
if android_match is None or int(android_match.group(1)) != int(app_match.group(1)):
    raise SystemExit("Android versionCode must match the unified App build version")
require(check, "test_dev136_catalog_weight_dead_code_compile.py", "repository check")
print("dev.136 catalog weight/dead-code compile contract: OK")
