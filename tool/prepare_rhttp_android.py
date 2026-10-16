#!/usr/bin/env python3
"""Apply the pinned rhttp 0.18.0 Cargokit Android SDK parsing fix."""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_SHA256 = '50f7345d872d2a77f2eb974087719b741f00b5b8fe47674767d410bedd00607c'
PATCHED_SHA256 = '5cd56540492ea330f34654e8d2c1919336c1f6cdca0085e2966570763e0b4750'
ORIGINAL = b'                    compileSdkVersion = plugin.project.android.compileSdkVersion.substring(8) as int\n'
REPLACEMENT = (
    b"                    def compileSdkVersionValue = plugin.project.android.compileSdkVersion?.toString() ?: ''\n"
    b'                    def compileSdkVersionMatch = compileSdkVersionValue.find(/\\d+/)\n'
    b'                    compileSdkVersion = compileSdkVersionMatch != null ? compileSdkVersionMatch as int : 33\n'
)


def resolve_plugin(config: Path) -> Path:
    packages = json.loads(config.read_text(encoding='utf-8'))['packages']
    package = next(p for p in packages if p['name'] == 'rhttp')
    uri = urlparse(urljoin(config.resolve().as_uri(), package['rootUri']))
    if uri.scheme != 'file' or uri.netloc:
        raise RuntimeError('rhttp must resolve to a local package directory')
    root = Path(unquote(uri.path))
    if re.search(r'^version:\s*0\.18\.0\s*$',
                 (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M) is None:
        raise RuntimeError('rhttp Android preparation requires pinned version 0.18.0')
    return root / 'cargokit/gradle/plugin.gradle'


def prepare_plugin(plugin: Path) -> bool:
    source = plugin.read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    if digest == PATCHED_SHA256:
        return False
    if digest != UPSTREAM_SHA256:
        raise RuntimeError(f'unrecognized rhttp Cargokit script: {plugin} ({digest})')
    patched = source.replace(ORIGINAL, REPLACEMENT)
    if hashlib.sha256(patched).hexdigest() != PATCHED_SHA256:
        raise RuntimeError('rhttp Cargokit patch does not match the pinned result')
    plugin.write_bytes(patched)
    return True


def main() -> None:
    config = ROOT / '.dart_tool/package_config.json'
    if not config.is_file():
        raise SystemExit('Run flutter pub get before preparing rhttp for Android')
    plugin = resolve_plugin(config)
    changed = prepare_plugin(plugin)
    print(f'rhttp Android SDK parsing: {"patched" if changed else "already prepared"}')


if __name__ == '__main__':
    main()
