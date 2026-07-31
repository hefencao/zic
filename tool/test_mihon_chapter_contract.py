#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
ABI_ROOTS = (
    ROOT / 'packages/plugin_host_bridge/android/src/mihonRuntime14/kotlin/eu/kanade/tachiyomi/source/online/HttpSource.kt',
    ROOT / 'packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/source/online/HttpSource.kt',
)


def main() -> int:
    raw_driver = DRIVER.read_bytes()
    if b'\x00' in raw_driver:
        raise SystemExit('Mihon runtime source contains an embedded NUL byte')
    driver = raw_driver.decode()
    required = (
        'selectMihonChapters(catalog.chapters)',
        'chapterById[chapterId]?.let { return it }',
        'mihonChapterMatches(chapter, encoded)',
        'if (chapters.isEmpty())',
        'MihonChapterSelection(chapters, synthetic = false)',
        'for (candidate in listOf("getChapterList", "fetchChapterList"))',
        'cause is UnsupportedOperationException',
        'newChapters',
        'loadMihonPageModels(source, selectedChapters.chapters.single(), requestId)',
        'Mihon source exposed neither a chapter catalog nor readable gallery pages',
        'catalog.chapterFailure?.let(error::addSuppressed)',
        'detailedChapters.isNotEmpty() -> detailedChapters',
        'mihonCoverResource(source, manga)',
        'return encodeOpaque("resource", resource)',
        'mihonContentKindHint(resource.optString("url"))',
        'put("animatedHint", kind == "webp" || kind == "gif")',
        'source.invokeMihonCompatible(candidate, listOf(chapterModel))',
        '"blockingGet"',
        '"value"',
    )
    for token in required:
        if token not in driver:
            raise SystemExit(f'Mihon chapter contract is incomplete: {token}')
    if '!chapterProbeCompleted' in driver:
        raise SystemExit('Mihon chapter failures are still hidden behind an empty probe')
    for source in ABI_ROOTS:
        text = source.read_text()
        if 'chapters.onEach { chapter -> prepareNewChapter(chapter, manga) }' not in text:
            raise SystemExit(f'Mihon ABI omits chapter normalization: {source}')

    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if kotlinc and java:
        match = re.search(
            r'internal data class MihonChapterSelection<T>\(.*?\n\)\n',
            driver,
            re.DOTALL,
        )
        function = re.search(
            r'internal inline fun <T> selectMihonChapters\(.*?\n}\n',
            driver,
            re.DOTALL,
        )
        if match is None or function is None:
            raise SystemExit('Mihon chapter selection helper could not be extracted')
        harness = f'''package dev.zic.pluginhost\n\n{match.group(0)}\n{function.group(0)}\nfun main() {{\n    var syntheticCalls = 0\n    val real = listOf("one", "two")\n    val selected = selectMihonChapters(real) {{ syntheticCalls++; "synthetic" }}\n    check(selected.chapters == real)\n    check(!selected.synthetic)\n    check(syntheticCalls == 0)\n    val empty = selectMihonChapters(emptyList<String>()) {{ syntheticCalls++; "正文" }}\n    check(empty.chapters == listOf("正文"))\n    check(empty.synthetic)\n    check(syntheticCalls == 1)\n}}\n'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'ChapterContract.kt'
            jar = root / 'chapter-contract.jar'
            source.write_text(harness)
            subprocess.run(
                [kotlinc, str(source), '-include-runtime', '-d', str(jar)],
                check=True,
            )
            subprocess.run([java, '-jar', str(jar)], check=True)

        unwrap = re.search(
            r'private fun Any\?\.unwrapAsync\(\): Any \{.*?\n\}',
            driver,
            re.DOTALL,
        )
        if unwrap is None:
            raise SystemExit('Mihon async adapter could not be extracted')
        async_harness = f'''package dev.zic.pluginhost
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Future

{unwrap.group(0)}

private class BlockingSingle(private val result: Any) {{ fun value(): Any = result }}
private class Rx1Single(private val result: Any) {{ fun toBlocking(): BlockingSingle = BlockingSingle(result) }}
private class Rx2Single(private val result: Any) {{ fun blockingGet(): Any = result }}

fun main() {{
    check((CompletableFuture.completedFuture(listOf("future")) as Future<*>).unwrapAsync() == listOf("future"))
    check(Rx1Single(listOf("rx1")).unwrapAsync() == listOf("rx1"))
    check(Rx2Single(listOf("rx2")).unwrapAsync() == listOf("rx2"))
}}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'AsyncContract.kt'
            jar = root / 'async-contract.jar'
            source.write_text(async_harness)
            subprocess.run(
                [kotlinc, str(source), '-include-runtime', '-d', str(jar)],
                check=True,
            )
            subprocess.run([java, '-jar', str(jar)], check=True)

    print('Mihon chapter catalog contract: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
