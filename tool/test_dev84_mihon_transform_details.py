#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

driver = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
domain = read('packages/domain/lib/src/models.dart')
source_catalog = read('packages/catalog/lib/src/source_catalog.dart')
saved = read('packages/catalog/lib/src/saved_comic.dart')
imported = read('packages/catalog/lib/src/imported_chapter.dart')
library = read('packages/catalog/lib/src/library_comic.dart')
details = read('apps/app/lib/comic_details.dart')
decode_test = read('packages/pipeline/test/decode_target_test.dart')
progress_test = read('packages/reader_runtime/test/reader_download_progress_test.dart')
progress = read('packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart')

for token in (
    'runtimeTransformBySource.computeIfAbsent(sourceId)',
    'mihonSourceRequiresRuntimeTransform(source)',
    '"requiresRuntimeTransform" to requiresRuntimeTransform',
    'capability.javaClass.classLoader === sourceLoader',
    'client.invokeOptional(name)?.let(::add)',
    'normalizedMihonSourceName(',
    'MIHON_RUNTIME_TRANSFORM_REVISION',
    'transportRevision = mihonTransportRevision(sourceId, source)',
    '"tags" to mihonGenres(manga)',
):
    assert token in driver, token
assert '"requiresRuntimeTransform" to false' not in driver

combined = driver.index('val updateChapters = update')
compatibility = driver.index('if (updateChapters.isEmpty() && detailedChapters.isEmpty())')
selection = driver.index('updateChapters.isNotEmpty() -> updateChapters')
assert combined < compatibility < selection
assert 'Invocation("getMangaUpdate"' in driver

for token in (
    'this.tags = const <String>[]',
    'final List<String> tags;',
):
    assert token in domain + source_catalog
for token in (
    "tags: _optionalStringList(item['tags'], 'tags')",
    "tags: _optionalStringList(comicValue['tags'], 'tags')",
):
    assert token in adapter
for text in (saved, imported, library):
    assert 'tags' in text or 'comicTags' in text

for token in (
    'tags: comic.tags',
    '_ExpandableTagRow(tags: tags)',
    "label: '下载整本'",
    'loading: downloadingComic',
    "label: Text('继续 · $progressLabel')",
    '_knownPageCount(chapter, entry)',
    '_chapterEntryFor(',
    'entry.chapter.sourceRevision != revision',
    'existing.chapter.sourceRevision == chapter.sourceRevision',
    '_replaceChapterEntry(_library.chapters, entry)',
    '_comicSourceLabel(widget.source',
):
    assert token in details, token
assert "FilledButton.tonalIcon(\n                          key: comicDetailsDownloadAllKey" not in details

assert 'expect(target.physicalWidth, 1024);' in decode_test
for unstable in ('Directory.systemTemp', 'testWidgets(', 'pumpAndSettle', 'Future.delayed'):
    assert unstable not in progress_test, unstable
assert 'pipelineTransferProgressFor(' in progress
assert 'restored and completed artifacts never project network progress' in progress_test

for path in (
    'docs/adr/0068-mihon-runtime-transform-catalog-and-details-metadata.md',
    'docs/audits/dev84-static-transform-mihon-details-audit.md',
):
    assert (ROOT / path).is_file(), path

print('dev.84 Mihon transform, catalog and details ownership: OK')
