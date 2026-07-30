#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

INTERNET_PERMISSION = (
    '    <uses-permission android:name="android.permission.INTERNET" />'
)
JITPACK_URL = 'https://jitpack.io'


def configure_android_manifest(manifest: Path) -> bool:
    text = manifest.read_text(encoding='utf-8')
    if 'android.permission.INTERNET' in text:
        return False

    manifest_start = text.find('<manifest')
    if manifest_start < 0:
        raise RuntimeError(f'Android manifest root not found: {manifest}')
    root_close = text.find('>', manifest_start)
    if root_close < 0:
        raise RuntimeError(f'Android manifest root is incomplete: {manifest}')

    insertion = f'\n{INTERNET_PERMISSION}'
    updated = text[: root_close + 1] + insertion + text[root_close + 1 :]
    manifest.write_text(updated, encoding='utf-8')
    return True


def _matching_brace(text: str, opening: int) -> int:
    depth = 0
    for index in range(opening, len(text)):
        char = text[index]
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return index
    raise RuntimeError('Gradle block is incomplete')


def _block_bounds(text: str, name: str, start: int = 0, end: int | None = None) -> tuple[int, int]:
    limit = len(text) if end is None else end
    match = re.search(
        rf'(?m)^\s*{re.escape(name)}\s*\{{',
        text[start:limit],
    )
    if match is None:
        raise RuntimeError(f'Gradle block not found: {name}')
    opening = text.find('{', start + match.start(), start + match.end())
    return opening, _matching_brace(text, opening)


def _inject_repository(
    text: str,
    *,
    owner_block: str,
    kotlin_dsl: bool,
) -> tuple[str, bool]:
    owner_open, owner_close = _block_bounds(text, owner_block)
    repositories_open, repositories_close = _block_bounds(
        text,
        'repositories',
        start=owner_open + 1,
        end=owner_close,
    )
    if JITPACK_URL in text[repositories_open:repositories_close]:
        return text, False

    line_start = text.rfind('\n', 0, repositories_open) + 1
    indent = re.match(r'[ \t]*', text[line_start:repositories_open]).group(0)
    repository = (
        f'{indent}    maven {{ url = uri("{JITPACK_URL}") }}'
        if kotlin_dsl
        else f'{indent}    maven {{ url "{JITPACK_URL}" }}'
    )
    updated = text[: repositories_open + 1] + f'\n{repository}' + text[repositories_open + 1 :]
    return updated, True


def _first_existing(*paths: Path) -> Path | None:
    return next((path for path in paths if path.is_file()), None)


def configure_android_dependency_repositories(android_dir: Path) -> tuple[Path, ...]:
    settings = _first_existing(
        android_dir / 'settings.gradle.kts',
        android_dir / 'settings.gradle',
    )
    root_build = _first_existing(
        android_dir / 'build.gradle.kts',
        android_dir / 'build.gradle',
    )

    target: Path
    owner_block: str
    if settings is not None and 'dependencyResolutionManagement' in settings.read_text(
        encoding='utf-8',
    ):
        target = settings
        owner_block = 'dependencyResolutionManagement'
    elif root_build is not None:
        target = root_build
        owner_block = 'allprojects'
    else:
        raise RuntimeError(
            f'Generated Android dependency repository owner not found: {android_dir}',
        )

    text = target.read_text(encoding='utf-8')
    canonicalized = text.replace('https://www.jitpack.io', JITPACK_URL)
    updated, injected = _inject_repository(
        canonicalized,
        owner_block=owner_block,
        kotlin_dsl=target.suffix == '.kts',
    )
    if not injected and canonicalized == text:
        return ()
    target.write_text(updated, encoding='utf-8')
    return (target,)


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Apply reproducible zic settings to generated Flutter hosts.',
    )
    parser.add_argument(
        '--app',
        type=Path,
        default=Path(__file__).resolve().parents[1] / 'apps' / 'app',
        help='Flutter app directory (default: apps/app)',
    )
    args = parser.parse_args()

    app = args.app.resolve()
    android_dir = app / 'android'
    android_manifest = android_dir / 'app' / 'src' / 'main' / 'AndroidManifest.xml'
    if not android_manifest.is_file():
        raise SystemExit(
            f'Android host is missing: {android_manifest}\n'
            'Run tool/bootstrap_platforms.sh first.',
        )

    manifest_changed = configure_android_manifest(android_manifest)
    manifest_state = 'updated' if manifest_changed else 'already configured'
    print(f'Android Internet permission: {manifest_state} ({android_manifest})')

    changed_repositories = configure_android_dependency_repositories(android_dir)
    if changed_repositories:
        for target in changed_repositories:
            print(f'Android JitPack repository: updated ({target})')
    else:
        print(f'Android JitPack repository: already configured ({android_dir})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
