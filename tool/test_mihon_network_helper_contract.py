#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


common_root = (
    'packages/plugin_host_bridge/android/src/mihonRuntimeCommon/kotlin/'
    'eu/kanade/tachiyomi/network/interceptor/'
)
interceptor = read(common_root + 'UncaughtExceptionInterceptor.kt')
for token in (
    'package eu.kanade.tachiyomi.network.interceptor',
    'class UncaughtExceptionInterceptor : Interceptor',
    'catch (error: Exception)',
    'if (error is IOException)',
    'throw error',
    'throw IOException(error)',
):
    if token not in interceptor:
        raise SystemExit(f'Mihon uncaught-exception interceptor contract missing: {token}')

user_agent = read(common_root + 'UserAgentInterceptor.kt')
for token in (
    'class UserAgentInterceptor(',
    'originalRequest.header("User-Agent").isNullOrEmpty()',
    '.addHeader("User-Agent", defaultUserAgentProvider())',
):
    if token not in user_agent:
        raise SystemExit(f'Mihon User-Agent interceptor contract missing: {token}')

cloudflare = read(common_root + 'CloudflareInterceptor.kt')
for token in (
    'class CloudflareInterceptor(',
    'private val delegate: Interceptor',
    'delegate.intercept(chain)',
):
    if token not in cloudflare:
        raise SystemExit(f'Mihon Cloudflare ABI shell contract missing: {token}')

for abi in ('mihonRuntime14', 'mihonRuntime16'):
    path = (
        'packages/plugin_host_bridge/android/src/'
        f'{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt'
    )
    source = read(path)
    for name in (
        'UncaughtExceptionInterceptor',
        'UserAgentInterceptor',
        'CloudflareInterceptor',
    ):
        import_token = (
            'import eu.kanade.tachiyomi.network.interceptor.'
            f'{name}'
        )
        if import_token not in source:
            raise SystemExit(
                f'{abi} NetworkHelper misses canonical {name} import',
            )

    builder = source.index('OkHttpClient.Builder()')
    uncaught = source.index(
        '.addInterceptor(UncaughtExceptionInterceptor())',
        builder,
    )
    user_agent = source.index(
        '.addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))',
        builder,
    )
    cookie = source.index('.cookieJar(cookieJar)', builder)
    browser_ua = source.index('.addInterceptor { chain ->', builder)
    cloudflare = source.index(
        '.addInterceptor(\n                CloudflareInterceptor(',
        builder,
    )
    delegate = source.index(
        'AndroidCloudflareInterceptor(context, ::defaultUserAgentProvider)',
        cloudflare,
    )
    if 'BrotliInterceptor' in source:
        raise SystemExit(f'{abi} default NetworkHelper must not install BrotliInterceptor')
    if not (
        builder < uncaught < user_agent < cookie < browser_ua
        < cloudflare < delegate
    ):
        raise SystemExit(
            f'{abi} NetworkHelper must keep the canonical Mihon default-client '
            'interceptors in order while delegating Cloudflare policy to '
            'network_bridge',
        )

build = read('packages/plugin_host_bridge/android/build.gradle')
if 'fileTree(mihonRuntimeCommonSources)' not in build:
    raise SystemExit('Mihon runtime-common sources are not compiled into ABI assets')

print('Mihon default NetworkHelper interceptor contract: OK')
