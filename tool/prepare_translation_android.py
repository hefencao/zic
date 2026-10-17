#!/usr/bin/env python3
"""Prepare pinned arm64 local-translation dependencies; never use the source app."""
from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PINNED = {
    'ctranslate2': '9ff9c719e62b98fb8a993c1629833b0ddab447db',
    'sentencepiece': '31646a467d2051eb904e0b45de3a73e91fe1c1e3',
    'llama': '031ddb2e08962837c899374297da75f91cc0157d',
    'kleidiai': 'c6b34654b7654d43a0f808bca3dd1cbc38e2bac9',
}
LIBRARIES = {
    'ctranslate2': ['ctranslate2'],
    'sentencepiece': ['sentencepiece'],
    'llama': ['llama', 'ggml', 'ggml-base', 'ggml-cpu'],
}


def valid_runtime(runtime: Path) -> bool:
    try:
        versions = json.loads((runtime / 'versions.json').read_text())
        if any(versions[key]['commit'] != commit for key, commit in PINNED.items()):
            return False
        patch = ROOT / 'tool/comic_translation/patches/llama-q2_0c-kleidiai.patch'
        if versions['llama']['feature_commit'] != 'a2baedad71a4d5685c83fe1939bb2e5f94e77f35':
            return False
        if versions['llama']['patch_sha256'] != hashlib.sha256(patch.read_bytes()).hexdigest():
            return False
        for license_name in ['kleidiai-Apache-2.0.txt', 'kleidiai-BSD-3-Clause.txt']:
            if not (runtime / 'licenses' / license_name).is_file():
                return False
        for package, names in LIBRARIES.items():
            if not (runtime / package / 'include').is_dir():
                return False
            if not (runtime / package / 'LICENSE').is_file():
                return False
            for name in names:
                path = runtime / package / 'lib/arm64-v8a' / f'lib{name}.so'
                with path.open('rb') as library:
                    header = library.read(20)
                if header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 183:
                    return False
        return True
    except (OSError, ValueError, KeyError, struct.error):
        return False


def main() -> None:
    native = Path(os.environ.get('ZIC_TRANSLATION_NATIVE_ROOT', ROOT / '.deps/comic_translation_native'))
    runtime = native / 'runtime'
    if not valid_runtime(runtime):
        subprocess.run([
            str(ROOT / 'tool/comic_translation/build_android_runtime.sh'),
            '--native-root', str(native), '--abis', 'arm64-v8a',
            '--jobs', os.environ.get('ZIC_TRANSLATION_BUILD_JOBS', '4'),
        ], check=True)
    if not valid_runtime(runtime):
        raise SystemExit('Pinned Android translation runtime is incomplete or invalid')
    print('Android translation runtime: pinned arm64 dependencies available')


if __name__ == '__main__':
    main()
