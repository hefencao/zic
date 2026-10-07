#!/usr/bin/env python3
"""Ownership gate for dev.296 source-canvas presentation aspect authority."""
import re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def read(path: str) -> str: return (ROOT / path).read_text(encoding='utf-8')
def require(path: str, *tokens: str) -> None:
    text = read(path); missing = [token for token in tokens if token not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.296 tokens: {missing}')
pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
dev_match = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
if dev_match is None or int(dev_match.group(1)) < 296:
    raise SystemExit('FAIL: dev.296+ app version missing')
if android_match is None or int(android_match.group(1)) < 296:
    raise SystemExit('FAIL: dev.296+ Android version missing')
current_dev = int(dev_match.group(1))
require('packages/pipeline_runtime/lib/src/pipeline_page_stream.dart','required this.sourceCanvasWidth,','required this.sourceCanvasHeight,','final int? sourceCanvasWidth;','final int? sourceCanvasHeight;','sourceCanvasWidth: snapshot.sourceCanvasWidth,','sourceCanvasHeight: snapshot.sourceCanvasHeight,')
require('packages/local_media_ui/lib/src/local_image_player.dart','final sourceCanvasWidth = snapshot.sourceCanvasWidth;','final sourceCanvasHeight = snapshot.sourceCanvasHeight;','authoritative: true,','decoded raster may be a rounded native')
require('packages/local_media_ui/lib/src/local_image_player.dart','if (!authoritative && _reportedDimensionsAuthoritative)','MediaAspectViewport(')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart','forwardEncodedPages: 7','backwardEncodedPages: 3','forwardDecodePages: 2','backwardDecodePages: 1')
require('docs/archive/adr/0275-source-canvas-presentation-aspect-authority.md','960x1950','952x1936','2.55px','decoded raster')
require('docs/archive/audits/dev296-source-canvas-presentation-aspect-audit.md','320 条 `pageLayoutSnapshot`','35.55555555555475','sourceCanvasWidth/sourceCanvasHeight','external Texture')
require('docs/ARCHITECTURE.md','最终aspect必须消费同一physical sourceCanvas authority')
require('docs/SPEC.md','MediaAspectViewport`的最终aspect authority')
print('dev.296 source-canvas presentation aspect authority: OK')
