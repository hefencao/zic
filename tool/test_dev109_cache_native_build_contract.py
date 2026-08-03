#!/usr/bin/env python3
"""Guard unified Reader artifact routing and Android native ABI closure."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"FAIL: {path} missing dev.109 tokens: {missing}")

def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f"FAIL: {path} contains rejected dev.109 tokens: {found}")

require(
    "packages/downloads/lib/src/artifact_cache_manager.dart",
    "final class ArtifactCacheManager",
    "LinkedHashMap<_ArtifactByteKey, Uint8List>",
    "Future<bool> containsBackend(",
    "readForegroundLookup(",
    "readSessionArtifact(",
)
require(
    "packages/downloads/lib/src/artifact_cache_store.dart",
    "abstract interface class ArtifactCacheBackend",
    "openArtifactStream(DownloadId id)",
    "storePromotedArtifact(",
)
forbid(
    "packages/downloads/lib/src/artifact_cache_store.dart",
    "ArtifactCacheStore",
    "ArtifactCacheStreamStore",
    "ArtifactCachePresenceStore",
)
for deleted in (
    "packages/downloads/lib/src/promoted_artifact_byte_cache.dart",
    "packages/downloads/test/promoted_artifact_byte_cache_test.dart",
):
    if (ROOT / deleted).exists():
        raise SystemExit(f"FAIL: obsolete cache layer remains: {deleted}")
require(
    "packages/downloads/lib/src/promoted_artifact_cache_handoff.dart",
    "cache.containsBackend(",
)
require(
    "native/media_core/src/android_texture.rs",
    "BLIT_OK_RECONFIGURED",
    "ANativeWindow_getWidth",
    "ANativeWindow_getHeight",
    "ANativeWindow_getFormat",
    "configure_if_needed(",
    "Java_dev_zic_texture_NativeBlitter_blit",
)
forbid(
    "native/media_core/src/android_texture.rs",
    "Java_dev_zic_texture_NativeBlitter_configure",
)
require(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt",
    "external fun blit(surface: Surface, frameAddress: Long): Int",
    "BLIT_OK_RECONFIGURED",
    '"surfaceReconfigureCount"',
)
forbid(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt",
    "external fun configure",
    "NativeBlitter.configure",
    "needsConfiguration",
)
require(
    "tool/build_android_native.sh",
    "ANDROID_NATIVE_BUILD_ID",
    ".zic-native-build-id",
)
require(
    "tool/check_android_native.sh",
    "Java_dev_zic_texture_NativeBlitter_blit",
    "Java_dev_zic_texture_NativeBlitter_configure",
    "stale or missing Android native build identity",
)
require(
    "apps/app/android/app/build.gradle.kts",
    "verifyZicNativeArtifacts",
    ".zic-native-build-id",
    'tasks.named("preBuild")',
)
print("dev.109 cache and Android native build contract: OK")
