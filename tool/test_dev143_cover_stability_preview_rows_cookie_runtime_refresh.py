#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.143 contract: {token}')

preview_all = read('apps/app/lib/comic_details_extras.dart')
preview = preview_all.split('final class _ComicDetailsCommentsSection', 1)[0]
artwork = read('apps/app/lib/artwork_placeholder.dart')
home = read('apps/app/lib/home_widgets.dart')
source = read('apps/app/lib/source_browser.dart')
details = read('apps/app/lib/comic_details.dart') + read('apps/app/lib/comic_details_interactions.dart')
home_source = read('apps/app/lib/home_shell_source_compat.dart')
source_test = read('apps/app/test/source_browser_test.dart')
refresh = read('apps/app/lib/app_pull_to_refresh.dart')
snapshot = read('packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/NetworkBrowserSnapshotStore.kt')
cookies = read('packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidBrowserCookieSession.kt')
channel = read('packages/plugin_host_bridge/lib/src/method_channel_runtime_backends.dart')
check = read('tool/check.sh')

for token in (
    'List<int> _takePreviewRowIndices(List<int> pending)',
    'if (_isLandscapePreview(first))',
    'if (landscapeOffset == 2 && configuredMaximum >= 2)',
    'final landscape = pending.removeAt(1)',
    'final inspectionCount = math.min(3, pending.length)',
    'areaRoot = availableItemWidth / rootSum',
    'targetArea = math.pow(areaRoot, 2)',
    'math.min(math.sqrt(targetArea / aspect), maxHeight)',
    'maximumSparseArea = referenceArea * 2.4',
    'alignment: Alignment.centerLeft',
    'const SizedBox(width: _previewGridGap)',
    'padding: const EdgeInsets.symmetric(vertical: 8)',
):
    require(preview, token, 'specialized preview rows')
for forbidden in (
    'residual / (row.items.length - 1)',
    'padding: const EdgeInsets.fromLTRB(12, 8, 12, 10)',
    'return Card(',
):
    if forbidden in preview:
        raise SystemExit(f'preview width waste remains: {forbidden}')

for token in (
    'final class StableArtworkImage',
    'Presentation does not own retry policy or encoded bytes.',
    'stays on one stable placeholder instead of starting presentation-owned retry',
):
    require(artwork, token, 'stable cover presentation')
for stale in ('Timer(', '.evict()', 'ArtworkRetryController', 'RecoverableArtworkImage'):
    if stale in artwork:
        raise SystemExit(f'presentation-owned cover recovery remains: {stale}')
if '(_loadFailed && oldWidget.loader != widget.loader)' in home:
    raise SystemExit('loader closure identity must not restart failed covers')
for owner, text in (('home', home), ('source', source), ('details', details)):
    require(text, 'SoftArtworkPlaceholder', f'{owner} stable retry placeholder')

for token in (
    'final class AppPullToRefresh',
    'RefreshIndicatorTriggerMode.onEdge',
    '_displacement = 72',
):
    require(refresh, token, 'shared pull refresh')
require(source, 'AppPullToRefresh(', 'source refresh usage')
require(details, 'AppPullToRefresh(', 'details refresh usage')
if 'RefreshIndicatorTriggerMode.anywhere' in details:
    raise SystemExit('details must not retain inconsistent anywhere refresh')

for token in (
    '"updatedAt" to updatedAt',
):
    require(snapshot, token, 'browser snapshot revision')
for token in (
    'importedSnapshotRevisions',
    '@Synchronized',
    'if (snapshot.revision <= importedRevision) return 0',
    'importedSnapshotRevisions[revisionKey] = snapshot.revision',
):
    require(cookies, token, 'one-shot cookie handoff')
for token in (
    '_recoverableRuntimeEnvelope(response)',
    'error.retryable',
    "'runtime-closing'",
):
    require(channel, token, 'runtime lifecycle recovery')


for token in (
    'typedef ComicDetailsSourceResolver',
    'Future<BrowsableComicSource> _sourceForOperation() async',
    'invalidateCachedComicMetadata(source, comicId)',
    "final source = await _sourceForOperation();",
    "widget.ensureSourceChapter(\n      source,",
):
    require(details, token, 'active source resolution')
require(details, 'final ComicDetailsSourceResolver? resolveSource;', 'canonical source resolver input')
require(source_test, 'Index 1 is landscape, so the actual first row contains exactly two', 'preview row owner test')
for token in (
    'resolveSource: _sourceForId',
    'final active = _sourceForId(source.sourceId) ?? source',
):
    require(home_source, token, 'current plugin source callbacks')

require(check, 'test_dev143_cover_stability_preview_rows_cookie_runtime_refresh.py', 'repository check')
version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 143:
    raise SystemExit('App build must be at least 143')
print('dev.143 cover stability / preview rows / cookie runtime / refresh: OK')
