#!/usr/bin/env python3
"""Compile the split Mihon extension loader against a minimal Android stub."""
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

kotlinc = shutil.which('kotlinc')
java = shutil.which('java')
if not kotlinc or not java:
    print('SKIP: kotlinc/java are not installed for Mihon split class loader compilation')
    raise SystemExit(0)

root = Path(__file__).resolve().parents[1]
source = (
    root
    / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
).read_text()
match = re.search(
    r'(internal fun isMihonParentFirstClass\(.*?\n\})'
    r'\n+(private class MihonExtensionClassLoader\(.*?\n\})'
    r'(?=\n\nprivate data class MihonAbiAsset)',
    source,
    re.S,
)
if not match:
    raise SystemExit('Mihon split class loader implementation not found')
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
        if (name == "eu.kanade.tachiyomi.extension.all.example.Entry" || name == "a") {
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
    parent_only.write_text('package eu.kanade.tachiyomi.source\nclass Source\n')
    obfuscated = work / 'Obfuscated.kt'
    obfuscated.write_text('class a\n')
    preference = work / 'Preference.kt'
    preference.write_text('package androidx.preference\nclass Preference\n')
    network_helper = work / 'NetworkHelper.kt'
    network_helper.write_text(
        'package eu.kanade.tachiyomi.network\nclass NetworkHelper\n'
    )
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
    check(loader.loadClass("eu.kanade.tachiyomi.extension.all.example.Entry").name == "dalvik.system.ChildMarker")
    check(loader.loadClass("a").name == "dalvik.system.ChildMarker")
    check(loader.loadClass("eu.kanade.tachiyomi.source.Source").name == "eu.kanade.tachiyomi.source.Source")
    check(loader.loadClass("eu.kanade.tachiyomi.network.NetworkHelper").name == "eu.kanade.tachiyomi.network.NetworkHelper")
    check(loader.loadClass("androidx.preference.Preference").name == "androidx.preference.Preference")
    check(loader.loadClass("okhttp3.OkHttpClient").name == "okhttp3.OkHttpClient")
    println("Mihon split class loader: OK")
}
'''
    )
    jar = work / 'smoke.jar'
    subprocess.run(
        ['kotlinc', str(stub), str(common), str(preference), str(network_helper), str(parent_only), str(obfuscated), str(smoke), '-include-runtime', '-d', str(jar)],
        check=True,
    )
    subprocess.run(['java', '-jar', str(jar)], check=True)
