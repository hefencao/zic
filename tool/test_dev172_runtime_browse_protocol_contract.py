#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')


protocol = read('packages/plugin_host/lib/src/runtime_protocol.dart')
for token in (
    'bool useFilters = false,',
    "'useFilters': useFilters",
    "optional: const <String>{'useFilters', 'freshNetwork'}",
    "arguments['useFilters'] is! bool",
    'Set<String> optional = const <String>{}',
):
    require(protocol, token, 'browse wire schema ownership')

adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
for token in (
    "'filterState': Map<String, Object?>.from(filterState)",
    "'useFilters': useFilters",
):
    require(adapter, token, 'browse adapter payload')

mihon = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
)
for token in (
    'val filterState = arguments["filterState"].asStringAnyMap("filterState")',
    'val useFilters = arguments["useFilters"] as? Boolean ?: false',
    'if (!useFilters && query.isBlank())',
):
    require(mihon, token, 'Mihon browse payload consumption')

venera = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'
)
require(venera, "if(request.operation==='browse')", 'Venera browse operation')
forbid(venera, "args.useFilters===true?", 'Venera-specific filter-mode branch')

protocol_test = read('packages/plugin_host/test/runtime_protocol_test.dart')
for token in (
    'useFilters: true,',
    "decoded.arguments['useFilters'], isTrue",
    'browse schema v1 accepts requests created before useFilters',
):
    require(protocol_test, token, 'runtime protocol regression coverage')

check = read('tool/check.sh')
for token in (
    'test_dev171_filter_shelf_download_feedback.py',
    'test_dev172_runtime_browse_protocol_contract.py',
):
    require(check, token, 'release gate wiring')

version = re.search(
    r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$',
    read('apps/app/pubspec.yaml'),
    re.M,
)
if version is None or int(version.group(1)) < 172:
    raise SystemExit('App build must be at least 172')
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.M,
)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.172 runtime browse protocol contract: OK')
