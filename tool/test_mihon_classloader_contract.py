#!/usr/bin/env python3
"""Compile the production child-first loader against a minimal Android stub."""
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (
    root
    / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
).read_text()
match = re.search(
    r'(internal fun isMihonChildFirstClass\(.*?\n    name\.startsWith\("eu\.kanade\.tachiyomi\."\))\n\n(private class MihonExtensionClassLoader\(.*?\n\})\n\nprivate data class MihonAbiAsset',
    source,
    re.S,
)
if not match:
    raise SystemExit('Mihon child-first class loader implementation not found')
policy, loader = match.groups()

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    stub = work / 'DexClassLoader.kt'
    stub.write_text(
        '''package dalvik.system

class ChildMarker

open class DexClassLoader(
    dexPath: String,
    optimizedDirectory: String,
    librarySearchPath: String?,
    parent: ClassLoader,
) : ClassLoader(parent) {
    override fun findClass(name: String): Class<*> {
        if (name == "eu.kanade.tachiyomi.source.Source") {
            return ChildMarker::class.java
        }
        throw ClassNotFoundException(name)
    }
}
'''
    )
    common = work / 'Common.kt'
    common.write_text('package okhttp3\nclass OkHttpClient\n')
    parent_only = work / 'ParentOnly.kt'
    parent_only.write_text('package eu.kanade.tachiyomi.parent\nclass Only\n')
    preference = work / 'Preference.kt'
    preference.write_text('package androidx.preference\nclass Preference\n')
    smoke = work / 'Smoke.kt'
    smoke.write_text(
        '''import dalvik.system.DexClassLoader
import java.io.File

'''
        + policy
        + '\n'
        + loader
        + '''

fun main() {
    val loader = MihonExtensionClassLoader(
        "x",
        File("."),
        null,
        ClassLoader.getSystemClassLoader(),
    )
    check(loader.loadClass("eu.kanade.tachiyomi.source.Source").name == "dalvik.system.ChildMarker")
    check(loader.loadClass("androidx.preference.Preference").name == "androidx.preference.Preference")
    check(loader.loadClass("okhttp3.OkHttpClient").name == "okhttp3.OkHttpClient")
    check(runCatching { loader.loadClass("eu.kanade.tachiyomi.parent.Only") }.isFailure)
    println("Mihon child-first class loader: OK")
}
'''
    )
    jar = work / 'smoke.jar'
    subprocess.run(
        ['kotlinc', str(stub), str(common), str(preference), str(parent_only), str(smoke), '-include-runtime', '-d', str(jar)],
        check=True,
    )
    subprocess.run(['java', '-jar', str(jar)], check=True)
