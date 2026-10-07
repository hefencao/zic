#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.311 history missing {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 311:
    raise SystemExit('dev.311 history version missing/regressed')

adr = read('docs/archive/adr/0290-reader-flutter-image-presentation-boundary.md')
audit = read('docs/archive/audits/dev311-reader-flutter-image-presentation-audit.md')
for token in (
    'Falsified by the 09:28 dev.311 device run',
    'renderer=flutterImage',
    '57', '28.194ms', '70', '31ms',
    'production default returns',
):
    require(adr + audit, token, 'falsification evidence')

native = read('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')
default_start = native.index('NativePipelineMediaRuntimeFactory() {')
default_end = native.index('\n  }', default_start) + 4
default_ctor = native[default_start:default_end]
require(default_ctor, 'AndroidTexturePresenter.isSupported', 'rolled-back production presenter')
if 'NativePipelineMediaRuntimeFactory.platformTexture()' in native:
    raise SystemExit('dev.311 experimental explicit-only texture default still active')

print('dev.311 Flutter-image presentation experiment: FALSIFIED and rolled back')
