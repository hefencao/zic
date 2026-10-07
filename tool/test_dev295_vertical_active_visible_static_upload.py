#!/usr/bin/env python3
"""Ownership gate for dev.295 native-static defer plus ADR0314 external-static staging."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.295 tokens: {missing}')

def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains superseded dev.295 tokens: {found}')

import re
pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
dev_match = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
if dev_match is None or int(dev_match.group(1)) < 295:
    raise SystemExit('FAIL: dev.295+ app version missing')
if android_match is None or int(android_match.group(1)) < 295:
    raise SystemExit('FAIL: dev.295+ Android version missing')
current_dev = int(dev_match.group(1))
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'final deadlineStaticPreupload =',
    'role == PageRole.next ||',
    'role == PageRole.next2 ||',
    'role == PageRole.previous;',
    'final deferHiddenVerticalNativeStaticUpload =',
    '!deadlineStaticPreupload &&',
    'runtimeExternalStaticPages.contains(entry.key)',
    '!externalStatic',
    'isPresentationMotionInteraction(observation.interaction)',
    '!deferHiddenVerticalNativeStaticUpload',
)
forbid(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'final deferVerticalNext2Upload =',
    'final deferHiddenVerticalStaticUpload =',
)
require(
    'packages/pipeline/lib/src/pipeline_controller.dart',
    '_runtimeExternalStaticPages',
    'externalPresentationRequired = false',
    "'runtimeExternalStaticPages': _runtimeExternalStaticPages.length",
)
require(
    'packages/sessions/lib/src/reader_binding.dart',
    'externalPresentationRequired = false',
    'externalPresentationRequired: externalPresentationRequired',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'sniffEncodedImageKind(download.readSourceMetadataPrefix())',
    '_isStaticFallbackImageKind(encodedKind)',
    'externalPresentationRequired: true',
    "'basis': 'encoded-prefix'",
)
require(
    'packages/pipeline/test/pipeline_test.dart',
    "'vertical active scroll preuploads native static deadline roles but defers far'",
    "'the existing next2 decode deadline must also own one prepared static output during active scroll'",
    "'active motion retains far upload identity but must not start speculative presentation work'" if current_dev >= 327 else "'active vertical motion still defers far speculative native static upload'",
    "'an exact external-static next page must retain staged first-frame work while the viewport is moving'",
)
require(
    'packages/pipeline_runtime/test/media_runtime_ownership_test.dart',
    "'exact fallback image prefix becomes runtime static evidence'",
    "'non-media fallback prefix never becomes runtime static evidence'",
)
require(
    'packages/reader/lib/src/reader_view.dart',
    'final scheduledPixels = metrics.pixels;',
    'final observedPixels = position?.pixels ?? scheduledPixels;',
    "'scheduledScrollPixels': scheduledPixels",
    'globalOrigin.dy + observedPixels - expected.start',
)
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
)
require(
    'docs/archive/adr/0274-vertical-active-visible-static-upload-boundary.md',
    'Superseded。',
    'ADR 0314',
    'hidden native/provisional texture',
)
require(
    'docs/archive/adr/0314-vertical-external-static-first-frame-staging.md',
    'Accepted。',
    'runtimeExternalStaticPages',
    '17/17 READY、0 BLACK',
    'localPresentationReady=false',
)
require(
    'docs/archive/adr/0323-vertical-active-deadline-static-prepresentation.md',
    'Accepted。',
    '`next`、`next2`、`previous`',
    '`far/near`',
    'UploadLane',
    'FrameBudgeter',
)
require(
    'docs/archive/audits/dev295-hidden-static-upload-jitter-audit.md',
    '333条`pageLayoutSnapshot`',
    '24.416ms',
    '14.809ms',
    '`deferHiddenVerticalStaticUpload`',
)
forbid('packages/reader/lib/src/reader_view.dart', 'presentationExtentAt(')
print('dev.295 vertical active visible-static upload boundary: OK')
