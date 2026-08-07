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
        'chapterById[chapterId]?.let { return it }',
        'mihonChapterMatches(chapter, encoded)',
        'for (candidate in listOf("getChapterList", "fetchChapterList"))',
        'val existingChapters = cachedMihonChaptersForComic(comicId)',
        'Invocation("getMangaUpdate", listOf(manga, existingChapters, true, true))',
        'private fun normalizeMihonChapterCatalog(chapters: List<Any>): List<Any>',
        'val locator = chapter.readString("url", "getUrl")',
        'mihonChapterMetadataScore(chapter)',
        'private fun mihonComicCatalogKey(comicId: String): String',
        'chapterIdsByComic[mihonComicCatalogKey(comicId)]',
        'val catalogKey = mihonComicCatalogKey(comicId)',
        'Mihon source exposes no compatible chapter-catalog operation',
        'cause is UnsupportedOperationException',
        'loadMihonPageModels(source, chapter, requestId)',
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
    # The explicit chapter API is the primary path. The combined 1.6 API may
    # only appear after the explicit chapter loop, otherwise normal legacy
    # sources perform duplicate or regressed network requests.
    if driver.index('for (candidate in listOf("getChapterList", "fetchChapterList"))') > driver.index('Invocation("getMangaUpdate", listOf(manga, existingChapters, true, true))'):
        raise SystemExit('Mihon combined update still suppresses/duplicates explicit chapter loading')
    forbidden = (
        'createSyntheticMihonChapter',
        'deduplicateMihonStartReadingEntries',
        'selectMihonChapters',
        'MihonChapterSelection',
        'MIHON_SYNTHETIC_REVISION',
        'detailedManga.readList("chapters"',
        'normalizeMihonStartReadingTitle',
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
