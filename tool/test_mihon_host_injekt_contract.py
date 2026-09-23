#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / (
    "packages/plugin_host_bridge/android/src/main/kotlin/"
    "dev/zic/pluginhost/MihonRuntimeDriver.kt"
)
source = DRIVER.read_text(encoding="utf-8")

for token in (
    '"kotlinx.serialization.json.Json"',
    'val (jsonType, json) = createMihonJson(classLoader)',
    'jsonType,\n        json,',
    'internal fun createMihonJson(classLoader: ClassLoader)',
    'getMethod("setIgnoreUnknownKeys", Boolean::class.javaPrimitiveType)',
    '.invoke(builder, true)',
    'getMethod("setExplicitNulls", Boolean::class.javaPrimitiveType)',
    '.invoke(builder, false)',
    'jsonType to json',
):
    if token not in source:
        raise SystemExit(f"Mihon host Injekt contract missing: {token}")

print("Mihon host Injekt Json contract: OK")
