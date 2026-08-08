#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.149 contract: {token}')


def forbid(text: str, token: str, owner: str) -> None:
    if token in text:
        raise SystemExit(f'{owner} retains obsolete dev.149 path: {token}')


bridge = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
    'PluginHostBridgePlugin.kt'
)
reader = read('packages/plugin_host_bridge/lib/src/android_mihon_metadata_reader.dart')
controller = read('packages/plugin_host_bridge/lib/src/external_plugin_controller.dart')
screen = read('apps/app/lib/external_plugin_repository_screen.dart')
manifest = read('apps/app/android/app/src/main/AndroidManifest.xml')
check = read('tool/check.sh')

for token in (
    '"scanInstalledMihonExtensions" -> scanInstalledMihonExtensions(call, result)',
    'private fun scanInstalledMihonPackages(',
    'runCatching { installedPackages() }',
    'runCatching { installedApplications() }',
    'knownPackageNames.forEach { packageName ->',
    'installedPackage(packageName)',
    '"failures" to failures.sortedWith(',
    '"enumerationErrors" to enumerationErrors',
    '"sharedExtensionOnly" to true',
):
    require(bridge, token, 'Android Mihon scan')
for token in (
    '.mapNotNull { runCatching',
    '.getOrNull() }\n        .map(::installedMihonExtension)',
):
    forbid(bridge, token, 'silent APK rejection')
require(manifest, 'android.permission.QUERY_ALL_PACKAGES', 'Android package visibility')

for token in (
    'final class InstalledMihonScan',
    'Future<InstalledMihonScan> scanInstalled(',
    "'scanInstalledMihonExtensions'",
    '.map((value) => value.trim())',
    'sharedExtensionOnly: value[\'sharedExtensionOnly\'] != false',
):
    require(reader, token, 'Dart Mihon scan mapping')
forbid(reader, '.map(String.trim)', 'invalid Dart instance-method tear-off')
forbid(controller, 'case final packageName?', 'fragile package-name pattern')

for token in (
    'scheduleMicrotask(_loadRepository);',
    'knownPackageNames: _knownMihonPackageNames',
    '仅检测系统共享 APK；Mihon 私有扩展请从 ZIC 仓库安装',
    '系统枚举 ${scan.enumeratedPackageCount} 个包',
    '识别失败（${scan.failures.length}）',
):
    require(screen, token, 'Mihon discovery UI')
require(check, 'test_dev149_mihon_end_to_end_discovery.py', 'repository check')
print('dev.149 Mihon end-to-end discovery contract: OK')
