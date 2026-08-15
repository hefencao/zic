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


# Flutter 3.44 pins test_api 0.7.11 in the user-validated toolchain. Keep the
# direct test constraint broad enough for that SDK resolver instead of forcing
# the newer test_api required by test ^1.31.2.
workspace_pubspecs = (
    list(ROOT.glob('pubspec.yaml')) +
    list(ROOT.glob('apps/*/pubspec.yaml')) +
    list(ROOT.glob('packages/*/pubspec.yaml'))
)
for pubspec in workspace_pubspecs:
    text = pubspec.read_text(encoding='utf-8')
    forbid(text, 'test: ^1.31.2', f'{pubspec.relative_to(ROOT)} incompatible test constraint')
    if re.search(r'^\s+test:\s*\^', text, re.M):
        require(text, 'test: ^1.25.0', f'{pubspec.relative_to(ROOT)} Flutter 3.44 test constraint')

plugins = (
    'local_media_bridge',
    'network_bridge',
    'plugin_host_bridge',
    'runtime_bridge',
    'texture_bridge',
)
for plugin in plugins:
    gradle = read(f'packages/{plugin}/android/build.gradle')
    require(gradle, 'com.android.tools.build:gradle:9.3.1', f'{plugin} AGP 9.3.1')
    require(gradle, 'JavaVersion.VERSION_17', f'{plugin} Android bytecode target 17')
    require(gradle, 'JvmTarget.JVM_17', f'{plugin} Kotlin bytecode target 17')

settings = read('apps/app/android/settings.gradle.kts')
require(settings, 'id("com.android.application") version "9.3.1" apply false', 'App AGP 9.3.1')
wrapper = read('apps/app/android/gradle/wrapper/gradle-wrapper.properties')
require(wrapper, 'gradle-9.5.0-all.zip', 'Gradle 9.5 wrapper')
daemon = read('apps/app/android/gradle/gradle-daemon-jvm.properties')
require(daemon, 'toolchainVersion=25', 'OpenJDK 25 Gradle daemon criteria')
app_gradle = read('apps/app/android/app/build.gradle.kts')
for token in (
    'compileSdk = 37',
    'sourceCompatibility = JavaVersion.VERSION_17',
    'targetCompatibility = JavaVersion.VERSION_17',
    'JvmTarget.JVM_17',
):
    require(app_gradle, token, 'App build-JDK/bytecode separation')

# Output retention and relative download/decode role are orthogonal. The
# immediate old current must remain offset -1 previous; retaining its uploaded
# output must not consume/skip the backward network slot.
role_window = read('packages/pipeline/lib/src/role_window.dart')
for token in (
    'this.retainedIndex,',
    'final int? retainedIndex;',
    'bool retains(int pageIndex) => retainedIndex == pageIndex;',
    'return RoleWindow(roles, retainedIndex: retainedIndex);',
):
    require(role_window, token, 'orthogonal retained output state')
forbid(role_window, '_setRole(roles, previousCurrentIndex, PageRole.last)', 'last role replacing previous')
forbid(role_window, 'roles[index] == PageRole.last', 'backward/forward last-slot skip')

policy = read('packages/pipeline/lib/src/heuristic_policy.dart')
for token in (
    'final retainedIndex = window.retainedIndex;',
    'role: PageRole.last,',
    "reason: 'heuristic:last-output-retained'",
):
    require(policy, token, 'upload-only last-output retention overlay')

controller = read('packages/pipeline/lib/src/pipeline_controller.dart')
for token in (
    'int? _previousRetainedIndex;',
    '_previousRetainedIndex != window.retainedIndex;',
    "'retainedIndex': window.retainedIndex",
):
    require(controller, token, 'retained output replan identity')

pipeline_test = read('packages/pipeline/test/pipeline_test.dart')
for token in (
    'previous current stays in previous window while its output is retained',
    'final latest = updates.last;',
    'latest.window.roleOf(2), PageRole.previous',
    '.priority,\n      780,',
    'far previous current retains output without redundant download',
    "isNot(contains('p2'))",
):
    require(pipeline_test, token, 'relative previous / far retention regression')

check = read('tool/check.sh')
require(check, 'test_dev180_openjdk25_previous_window_owner.py', 'dev.180 release gate wiring')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if version is None or int(version.group(1)) < 180 or android is None or android.group(1) != version.group(1):
    raise SystemExit('dev.180 version floor / Android parity mismatch')

print('dev.180 OpenJDK25 + relative previous window contract: OK')
