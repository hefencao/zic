#!/usr/bin/env python3
from __future__ import annotations

import tempfile
from pathlib import Path

from configure_platforms import (
    JITPACK_URL,
    OPENCV_REPOSITORY_MARKER,
    configure_android_dependency_repositories,
    configure_android_manifest,
)


def _write_manifest(root: Path) -> Path:
    manifest = root / 'app' / 'src' / 'main' / 'AndroidManifest.xml'
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <application android:label="zic" />\n'
        '</manifest>\n',
        encoding='utf-8',
    )
    return manifest


def _test_manifest(android: Path) -> None:
    manifest = _write_manifest(android)
    assert configure_android_manifest(manifest) is True
    assert configure_android_manifest(manifest) is False
    text = manifest.read_text(encoding='utf-8')
    assert text.count('android.permission.INTERNET') == 1
    assert text.index('<uses-permission') < text.index('<application')


def _test_groovy_repository(android: Path) -> None:
    (android / 'settings.gradle').write_text(
        'pluginManagement {\n'
        '    repositories {\n'
        '        google()\n'
        '        mavenCentral()\n'
        '    }\n'
        '}\n',
        encoding='utf-8',
    )
    build = android / 'build.gradle'
    build.write_text(
        'allprojects {\n'
        '    repositories {\n'
        '        google()\n'
        '        mavenCentral()\n'
        '        maven { url "https://www.jitpack.io" }\n'
        '    }\n'
        '}\n',
        encoding='utf-8',
    )
    assert configure_android_dependency_repositories(android) == (build,)
    assert configure_android_dependency_repositories(android) == ()
    text = build.read_text(encoding='utf-8')
    assert text.count(JITPACK_URL) == 1
    assert 'https://www.jitpack.io' not in text
    assert f'maven {{ url "{JITPACK_URL}" }}' in text
    assert text.count(OPENCV_REPOSITORY_MARKER) == 1
    assert '/opencv-runtime/maven' in text


def _test_kotlin_settings_repository(android: Path) -> None:
    settings = android / 'settings.gradle.kts'
    settings.write_text(
        'pluginManagement {\n'
        '    repositories {\n'
        '        google()\n'
        '        mavenCentral()\n'
        '    }\n'
        '}\n'
        'dependencyResolutionManagement {\n'
        '    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)\n'
        '    repositories {\n'
        '        google()\n'
        '        mavenCentral()\n'
        '    }\n'
        '}\n',
        encoding='utf-8',
    )
    build = android / 'build.gradle.kts'
    build.write_text(
        'allprojects {\n'
        '    repositories {\n'
        '        google()\n'
        '        mavenCentral()\n'
        '    }\n'
        '}\n',
        encoding='utf-8',
    )
    assert configure_android_dependency_repositories(android) == (settings,)
    assert configure_android_dependency_repositories(android) == ()
    settings_text = settings.read_text(encoding='utf-8')
    build_text = build.read_text(encoding='utf-8')
    assert settings_text.count(JITPACK_URL) == 1
    assert f'maven {{ url = uri("{JITPACK_URL}") }}' in settings_text
    assert JITPACK_URL not in build_text
    assert settings_text.count(OPENCV_REPOSITORY_MARKER) == 1
    assert OPENCV_REPOSITORY_MARKER not in build_text


def main() -> int:
    with tempfile.TemporaryDirectory(prefix='zic-platform-test-') as directory:
        root = Path(directory)
        groovy_android = root / 'groovy' / 'android'
        groovy_android.mkdir(parents=True)
        _test_manifest(groovy_android)
        _test_groovy_repository(groovy_android)

        kotlin_android = root / 'kotlin' / 'android'
        kotlin_android.mkdir(parents=True)
        _test_kotlin_settings_repository(kotlin_android)

    print('generated Android host configuration: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
