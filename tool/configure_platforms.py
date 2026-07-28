#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

INTERNET_PERMISSION = (
    '    <uses-permission android:name="android.permission.INTERNET" />'
)


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
    android_manifest = app / 'android' / 'app' / 'src' / 'main' / 'AndroidManifest.xml'
    if not android_manifest.is_file():
        raise SystemExit(
            f'Android host is missing: {android_manifest}\n'
            'Run tool/bootstrap_platforms.sh first.',
        )

    changed = configure_android_manifest(android_manifest)
    state = 'updated' if changed else 'already configured'
    print(f'Android Internet permission: {state} ({android_manifest})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
