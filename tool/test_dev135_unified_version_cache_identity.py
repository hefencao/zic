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
views = (ROOT / 'apps/app/lib/demo_home_views.dart').read_text(encoding='utf-8')
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
    "segments.indexOf('s')",
    "'checksum:$checksum'",
):
    require(reuse, token, 'verified E-Hentai-style cache reuse')
for unsafe in ('title ==', 'authors', 'page.index'):
    reject(reuse, unsafe, 'unsafe cache-reuse matching')

# Production app has one active response-cache composition root and one active
# Reader artifact-cache root. DemoHome constructs the bootstrap root and the
# durable service handoff constructs its replacement; UI widgets must not
# create any additional private managers.
app_sources = '\n'.join(
    path.read_text(encoding='utf-8')
    for path in (ROOT / 'apps/app/lib').glob('*.dart')
)
if 'ResourceCacheManager(' in app_sources:
    raise SystemExit('App UI must not create a private ResourceCacheManager')
if len(re.findall(r'(?<!with)ArtifactCacheManager\(', app_sources)) != 2:
    raise SystemExit(
        'App must retain only bootstrap and durable-handoff artifact caches'
    )

print('dev.135 unified version/cache identity contract: OK')
