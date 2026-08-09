#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'forbidden {label}: {token}')


# Modern stable Flutter/Dart floor across the workspace.
for pubspec in ROOT.rglob('pubspec.yaml'):
    text = pubspec.read_text(encoding='utf-8')
    if "sdk: '>=3.12.0 <4.0.0'" not in text:
        raise SystemExit(f'{pubspec.relative_to(ROOT)} does not require Dart >=3.12')
    if re.search(r'^\s+flutter:\s*$', text, re.M) or 'sdk: flutter' in text:
        if "flutter: '>=3.44.0'" not in text:
            raise SystemExit(f'{pubspec.relative_to(ROOT)} does not require Flutter >=3.44')

for path, token in (
    ('packages/downloads_bridge/pubspec.yaml', 'rhttp: 0.18.0'),
    ('packages/storage/pubspec.yaml', 'sqlite3: ^3.5.0'),
    ('packages/storage_bridge/pubspec.yaml', 'path_provider: ^2.1.6'),
    ('packages/bridge/pubspec.yaml', 'ffi: ^2.2.0'),
    ('packages/plugin_host/pubspec.yaml', 'crypto: ^3.0.7'),
    ('apps/app/pubspec.yaml', 'file_selector: ^1.1.0'),
    ('apps/app/pubspec.yaml', 'flutter_lints: ^6.0.0'),
):
    require(read(path), token, f'dependency baseline {path}')

# Local Flutter plugins must stop applying KGP themselves so they can consume
# AGP built-in Kotlin once Flutter enables it. Stable Flutter 3.44 still keeps
# the app compatibility flag disabled until Flutter 3.47+.
plugins = (
    'local_media_bridge',
    'network_bridge',
    'plugin_host_bridge',
    'runtime_bridge',
    'texture_bridge',
)
for plugin in plugins:
    path = f'packages/{plugin}/android/build.gradle'
    gradle = read(path)
    for token in (
        'compilerOptions',
        'JvmTarget.JVM_17',
    ):
        require(gradle, token, f'{plugin} built-in Kotlin migration')
    forbid(gradle, "apply plugin: 'kotlin-android'", f'{plugin} legacy KGP application')
    forbid(gradle, 'org.jetbrains.kotlin:kotlin-gradle-plugin', f'{plugin} embedded KGP classpath')
    forbid(gradle, 'kotlinOptions', f'{plugin} legacy kotlinOptions')

settings = read('apps/app/android/settings.gradle.kts')
require(settings, 'id("org.jetbrains.kotlin.android") version "2.4.10" apply false', 'legacy compatibility KGP pin')
app_gradle = read('apps/app/android/app/build.gradle.kts')
require(app_gradle, 'compileSdk = 37', 'API 37 compile SDK')
props = read('apps/app/android/gradle.properties')
require(props, 'android.builtInKotlin=false', 'stable Flutter built-in Kotlin compatibility flag')
require(props, 'android.newDsl=false', 'stable Flutter AGP DSL compatibility flag')

plugin_host_gradle = read('packages/plugin_host_bridge/android/build.gradle')
for token in (
    'kotlinx-serialization-json:1.11.0',
    'gson:2.14.0',
    'kotlin-stdlib-jdk8:2.4.10',
    'kotlinx-coroutines-core:1.11.0',
    'org.json:json:20260522',
):
    require(plugin_host_gradle, token, 'safe Maven dependency upgrade')

# dev.182 proved transport-level 64/256 KiB framing was a duplicate owner.
# rhttp must expose streaming packets to DownloadJob, which already owns the
# sole 16 KiB startup / source-progress-quantum aggregation boundary.
transport = read('packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart')
require(transport, 'yield chunk;', 'raw rhttp stream forwarding to DownloadJob')
forbid(transport, 'RhttpChunkCoalescer', 'duplicate rhttp packet coalescer')
if (ROOT / 'packages/downloads_bridge/lib/src/rhttp_chunk_coalescer.dart').exists():
    raise SystemExit('superseded rhttp chunk coalescer implementation still exists')
if (ROOT / 'packages/downloads_bridge/test/rhttp_chunk_coalescer_test.dart').exists():
    raise SystemExit('superseded rhttp chunk coalescer regression still exists')
job = read('packages/sessions/lib/src/download_job.dart')
for token in (
    'var flushTarget = 16 * 1024;',
    'flushTarget = sourceProgressQuantumBytes;',
    'final pending = BytesBuilder(copy: false);',
):
    require(job, token, 'single DownloadJob framing owner')
job_test = read('packages/sessions/test/download_job_test.dart')
require(job_test, 'coalesces tiny transport chunks before native/artifact ingress', 'DownloadJob framing regression')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if version is None or int(version.group(1)) < 179 or android is None or android.group(1) != version.group(1):
    raise SystemExit('dev.179+ version mismatch')

print('dev.179 toolchain + rhttp stream framing contract: OK')
