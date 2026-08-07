#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / (
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
    'MihonRuntimeDriver.kt'
)
RULES = ROOT / 'packages/network_bridge/android/consumer-rules.pro'
CHECK = ROOT / 'tool/check.sh'


def fail(message: str) -> None:
    raise SystemExit(message)


driver = DRIVER.read_text(encoding='utf-8')
rules = RULES.read_text(encoding='utf-8')
check = CHECK.read_text(encoding='utf-8')

match = re.search(
    r'internal val requiredMihonCommonRuntimeClasses: List<String> = listOf\((.*?)\n\)',
    driver,
    re.S,
)
if match is None:
    fail('requiredMihonCommonRuntimeClasses could not be parsed')

network_classes = re.findall(r'"(dev\.zic\.network\.[A-Za-z0-9_.$]+)"', match.group(1))
if not network_classes:
    fail('Mihon common runtime declares no network boundary classes')

missing = [
    class_name
    for class_name in network_classes
    if f'-keep class {class_name} {{ *; }}' not in rules
]
if missing:
    fail(
        'network runtime classes used by dynamic Mihon ABI lack release keep rules: '
        + ', '.join(missing)
    )

required = 'dev.zic.network.SourceVerificationRequiredException'
if required not in network_classes:
    fail('typed source verification failure is absent from common runtime ABI')
if f'-keep class {required} {{ *; }}' not in rules:
    fail('typed source verification failure can be renamed/removed by R8')
if 'test_dev150_mihon_runtime_release_keep.py' not in check:
    fail('dev.150 gate is not wired into tool/check.sh')

print('dev.150 Mihon runtime release keep boundary: OK')
