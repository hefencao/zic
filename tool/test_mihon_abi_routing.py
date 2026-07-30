#!/usr/bin/env python3
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (
    root
    / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
).read_text()
parts = []
for pattern in (
    r'internal val supportedMihonExtensionLibs:.*?\n\ninternal fun mihonAbiAssetVersion\(.*?\n\}',
    r'internal fun isMihonChildFirstClass\(.*?\n    name\.startsWith\("eu\.kanade\.tachiyomi\."\)',
):
    match = re.search(pattern, source, re.S)
    if not match:
        raise SystemExit(f'Mihon ABI routing helper missing: {pattern}')
    parts.append(match.group(0))

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    smoke = work / 'Smoke.kt'
    smoke.write_text(
        '\n\n'.join(parts)
        + '''
fun main() {
    check(mihonAbiAssetVersion("1.4") == "1.4")
    check(mihonAbiAssetVersion("1.5") == "1.6")
    check(mihonAbiAssetVersion("1.6") == "1.6")
    check(isMihonChildFirstClass("eu.kanade.tachiyomi.extension.all.ehentai.EHFactory"))
    check(!isMihonChildFirstClass("androidx.preference.Preference"))
    check(!isMihonChildFirstClass("okhttp3.OkHttpClient"))
    println("Mihon ABI routing: OK")
}
'''
    )
    jar = work / 'smoke.jar'
    subprocess.run(
        ['kotlinc', str(smoke), '-include-runtime', '-d', str(jar)],
        check=True,
    )
    subprocess.run(['java', '-jar', str(jar)], check=True)
