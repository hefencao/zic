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
        'catalog.chapterFailure?.let { throw it }',
        'val combined = try',
        'listOf(manga, existingChapters, true, true)',
        'source.invokeMihonCompatible("fetchChapterList", listOf(manga))',
        'source.invokeMihonCompatible("getPageList", listOf(chapter))',
        'source.invokeMihonCompatible("fetchPageList", listOf(chapter))',
        'val existingChapters = cachedMihonChaptersForComic(source, comicId)',
        'private fun mihonSourceCacheKey(source: Any): String',
        'private fun mihonChapterCacheKey(source: Any, chapterId: String): String',
        'chapterById[mihonChapterCacheKey(source, chapterId)]',
        'Mihon source exposes no compatible chapter-catalog operation',
        'Mihon source exposes no compatible page-list operation',
        'cause !is UnsupportedOperationException',
        'loadMihonPageModels(source, chapter, requestId)',
        'mihonCoverResource(source, manga)',
        'mihonRequestResource(source.javaClass.classLoader, request)',
        'mihonContentKindHint(resource.optString("url"))',
        'put("animatedHint", kind == "webp" || kind == "gif")',
        '"blockingGet"',
        '"value"',
    )
    for token in required:
        if token not in driver:
            raise SystemExit(f'Mihon chapter contract is incomplete: {token}')
    # Current Source/TachiyomiX 1.6 enters through getMangaUpdate; the legacy
    # fetchChapterList/fetchPageList APIs are capability fallbacks only.
    combined = driver.index('val combined = try')
    legacy_catalog = driver.index('source.invokeMihonCompatible("fetchChapterList"')
    current_pages = driver.index('source.invokeMihonCompatible("getPageList"')
    legacy_pages = driver.index('source.invokeMihonCompatible("fetchPageList"')
    if combined >= legacy_catalog:
        raise SystemExit('Mihon legacy chapter API still runs before current getMangaUpdate')
    if current_pages >= legacy_pages:
        raise SystemExit('Mihon legacy page API still runs before current getPageList')
    forbidden = (
        'createSyntheticMihonChapter',
        'deduplicateMihonStartReadingEntries',
        'selectMihonChapters',
        'MihonChapterSelection',
        'MIHON_SYNTHETIC_REVISION',
        'detailedManga.readList("chapters"',
        'normalizeMihonStartReadingTitle',
        'normalizeMihonChapterCatalog',
        'mihonChapterMetadataScore',
        'for (candidate in listOf("getChapterList", "fetchChapterList"))',
        'source.invokeMihonCompatible("getChapterList"',
        'source.invokeMihonCompatible("fetchChapterList", listOf(detailedManga))',
        'fetchMangaUpdate',
        '开始阅读"',
    )
    for token in forbidden:
        if token in driver:
            raise SystemExit(f'Mihon chapter contract retains guessed host behavior: {token}')
    if '!chapterProbeCompleted' in driver:
        raise SystemExit('Mihon chapter failures are still hidden behind an empty probe')
    for source in ABI_ROOTS:
        text = source.read_text()
        if 'chapters.onEach { chapter -> prepareNewChapter(chapter, manga) }' not in text:
            raise SystemExit(f'Mihon ABI omits chapter normalization: {source}')

    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if kotlinc and java:
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
