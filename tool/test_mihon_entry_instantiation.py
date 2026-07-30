#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if not kotlinc or not java:
        print('SKIP: kotlinc/java are not installed for Mihon entry helper execution')
        return 0

    source = SOURCE.read_text(encoding='utf-8')
    match = re.search(
        r'internal fun instantiateMihonEntry\(.*?\n}\n\nprivate fun emptyFilterList',
        source,
        re.S,
    )
    if not match:
        raise SystemExit('instantiateMihonEntry helper not found')
    helper = match.group(0).removesuffix('\n\nprivate fun emptyFilterList')

    with tempfile.TemporaryDirectory() as raw_temp:
        temp = Path(raw_temp)
        context = temp / 'Context.kt'
        context.write_text('package android.content\nopen class Context\n', encoding='utf-8')
        smoke = temp / 'MihonEntryInstantiationSmoke.kt'
        smoke.write_text(
            f'''package dev.zic.pluginhost

import android.content.Context
import java.lang.reflect.Modifier

{helper}

object ObjectEntry
class ContextEntry(val context: Context)
class NoArgEntry
class FactoryEntry private constructor(val context: Context) {{
    companion object {{
        @JvmStatic fun create(context: Context): FactoryEntry = FactoryEntry(context)
    }}
}}
class SpecificContext : Context()
class SpecificContextEntry(val context: SpecificContext)
abstract class AbstractEntry

fun main() {{
    val context = Context()
    check(instantiateMihonEntry(ObjectEntry::class.java, context) === ObjectEntry)
    check((instantiateMihonEntry(ContextEntry::class.java, context) as ContextEntry).context === context)
    check(instantiateMihonEntry(NoArgEntry::class.java, context) is NoArgEntry)
    check((instantiateMihonEntry(FactoryEntry::class.java, context) as FactoryEntry).context === context)
    check(runCatching {{ instantiateMihonEntry(SpecificContextEntry::class.java, context) }}.isFailure)
    check(runCatching {{ instantiateMihonEntry(AbstractEntry::class.java, context) }}.isFailure)
    println("Mihon entry instantiation helper: OK")
}}
''',
            encoding='utf-8',
        )
        jar = temp / 'mihon-entry-instantiation.jar'
        subprocess.run(
            [kotlinc, str(context), str(smoke), '-include-runtime', '-d', str(jar)],
            check=True,
        )
        subprocess.run([java, '-jar', str(jar)], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
