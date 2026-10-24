#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'{label}: missing {token!r}')


def reject(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'{label}: forbidden {token!r}')


version_properties = (
    ROOT / 'apps/app/android/zic-version.properties'
).read_text(encoding='utf-8')
app_pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
gradle = (ROOT / 'apps/app/android/app/build.gradle.kts').read_text(
    encoding='utf-8'
)
version_name = re.search(r'^versionName=(.+)$', version_properties, re.M)
version_code = re.search(r'^versionCode=(\d+)$', version_properties, re.M)
if version_name is None or version_code is None:
    raise SystemExit('Android project version properties are incomplete')
if f'version: {version_name.group(1)}+{version_code.group(1)}' not in app_pubspec:
    raise SystemExit('pubspec and Android project-owned version diverge')
for token in (
    'versionCode = zicVersionCode',
    'versionName = zicVersionName',
    'applicationId = "dev.zic.zic"',
    'applicationIdSuffix = null',
    'versionNameSuffix = null',
):
    require(gradle, token, 'unified Android package identity')
reject(gradle, 'versionCode = flutter.versionCode', 'unified Android version')
reject(gradle, 'versionName = flutter.versionName', 'unified Android version')

cache_identity = (
    ROOT / 'packages/catalog/lib/src/cache_identity.dart'
).read_text(encoding='utf-8')
for token in (
    'encodeStableCacheKey',
    "'zic-key-v1:'",
    'ComicResourceCacheIdentity',
    "response('details')" if False else 'comic-response',
):
    require(cache_identity, token, 'stable catalog cache identity')

cached_source = (
    ROOT / 'packages/catalog/lib/src/cached_comic_source.dart'
).read_text(encoding='utf-8')
for token in (
    "identity.response(resourceRole)",
    "encodeStableCacheKey(\n        'source-image'",
    "resourceRole = 'cover'",
    'canonicalComicIdentity(comicId)',
):
    require(cached_source, token, 'stable cover cache route')
for token in (
    'legacyComicId',
    '_legacyImageKey',
    'readBytesIfPresent',
    'copyEncodedImage',
    'mirrorCachedComicImageAlias',
):
    reject(cached_source, token, 'obsolete app-update cover-key migration')

home = (ROOT / 'apps/app/lib/home_widgets.dart').read_text(encoding='utf-8')
views = (ROOT / 'apps/app/lib/home_shell_views.dart').read_text(encoding='utf-8')
for token in (
    'required this.coverIdentity',
    'cacheIdentity: coverIdentity',
):
    require(home, token, 'canonical cover widget identity')
require(views, 'final coverIdentity = _canonicalComicKey(', 'canonical cover composition identity')
reject(home, 'String _coverRequestIdentity(LibraryComic comic) => comic.identity;', 'raw cover widget identity')
reject(home, "sourceValue ?? ''", 'cover widget identity')

venera = (
    ROOT
    / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'
).read_text(encoding='utf-8')
for token in (
    "function __zicStableComicId(rawId)",
    "__zicB64({v:2,id:String(rawId??'')})",
    "__zicB64({v:2,comicId,comicRawId,epId:normalizedEpId})",
    'const __zicChapterMeta=new Map()',
):
    require(venera, token, 'stable Venera identity')
reject(
    venera,
    "__zicB64({id:rawId,title:",
    'mutable Venera comic identity',
)
reject(
    venera,
    'epId:epId==null?null:String(epId),title:String(title),sequence:index',
    'mutable Venera chapter identity',
)

artifact = (
    ROOT / 'packages/downloads/lib/src/artifact_cache_manager.dart'
).read_text(encoding='utf-8')
reuse = (
    ROOT / 'packages/downloads/lib/src/artifact_cache_reuse.dart'
).read_text(encoding='utf-8')
identity_terms = (
    ROOT / 'packages/storage/lib/src/cache_record_query.dart'
).read_text(encoding='utf-8')
reuse_test = (
    ROOT / 'packages/downloads/test/artifact_cache_reuse_test.dart'
).read_text(encoding='utf-8')
build = int(version_code.group(1))
if build >= 230:
    for token in (
        'LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>> _equivalents',
        'void linkEquivalent({',
        'final DownloadId storageId;',
        'final Map<DownloadId, DownloadId> mappings;',
        'int registerEquivalences(ArtifactCacheManager cache) {',
    ):
        require(artifact + reuse, token, 'verified equivalence cache reuse')
    for token in (
        'LinkedHashMap<DownloadId, DownloadId> _aliases',
        'DownloadId resolveAlias(DownloadId id)',
        'void alias({',
        'Future<bool> rekey({',
        'Future<int> rekeyExisting',
        'Future<int> applyExisting',
    ):
        reject(artifact + reuse, token, 'superseded hard artifact alias/rekey')
else:
    for token in (
        'LinkedHashMap<DownloadId, DownloadId> _aliases',
        'DownloadId resolveAlias(DownloadId id)',
        'void alias({',
        'Future<bool> rekey({',
        'circular artifact cache alias',
        'final DownloadId storageId;',
    ):
        require(artifact, token, 'artifact alias/rekey')
    require(reuse, 'Future<int> rekeyExisting', 'verified E-Hentai-style cache reuse')
for token in (
    'VerifiedArtifactReusePlan',
    "'checksum:$checksum'",
    'yield* cacheUriIdentityTerms(page.uri);',
    'cacheRecordIdentityTerms(record);',
):
    require(reuse, token, 'verified E-Hentai-style cache reuse')
for token in (
    "segments.indexOf('s')",
    "yield 'eh:$imageKey'",
    "yield 'hash:$hash'",
    "yield 'checksum:$algorithm:$checksum'",
):
    require(identity_terms, token, 'shared indexed cache identity projection')
for unsafe in ('title ==', 'authors'):
    reject(reuse, unsafe, 'unsafe cache-reuse matching')
for token in (
    'final index = id.pageIndexHint;',
    'page.index != index',
    'page.pageId != id.content.pageId',
    'page.uri != id.canonicalUri',
    'final identity = verifiedPageIdentity(page);',
):
    require(reuse, token, 'validated non-identity page-index hint')
for token in (
    'page index or title similarity alone never creates reuse aliases',
    'version resolver requires a validated non-identity page index hint',
):
    require(reuse_test, token, 'cache-reuse negative identity coverage')

# Production app has one response-cache composition authority and one
# generation-bound Reader artifact-cache construction owner. Bootstrap and
# durable handoff both use HomeServiceCacheBinding.create(); UI widgets and
# handoff adapters must not duplicate private manager construction.
app_lib = ROOT / 'apps/app/lib'
app_files = tuple(app_lib.glob('*.dart'))
app_sources = '\n'.join(path.read_text(encoding='utf-8') for path in app_files)
if 'ResourceCacheManager(' in app_sources:
    raise SystemExit('App UI must not create a private ResourceCacheManager')
artifact_cache_constructors = [
    path.relative_to(ROOT).as_posix()
    for path in app_files
    if re.search(r'(?<!with)ArtifactCacheManager\(', path.read_text(encoding='utf-8'))
]
if artifact_cache_constructors != ['apps/app/lib/home_service_cache_binding.dart']:
    raise SystemExit(
        'ArtifactCacheManager construction must be owned only by '
        'HomeServiceCacheBinding: ' + repr(artifact_cache_constructors)
    )

print('dev.135 unified version/cache identity contract: OK')
