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
    driver = DRIVER.read_text()
    required = (
        'selectMihonChapters(catalog.chapters)',
        'chapterById[chapterId]?.let { return it }',
        'mihonChapterMatches(chapter, encoded)',
        'if (chapters.isEmpty())',
        'MihonChapterSelection(chapters, synthetic = false)',
    )
    for token in required:
        if token not in driver:
            raise SystemExit(f'Mihon chapter contract is incomplete: {token}')
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

    print('Mihon chapter catalog contract: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
