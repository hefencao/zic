#!/usr/bin/env python3
"""Guard dev.282 retained Android texture resident presentation ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def req(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(message)


def require(path: str, *needles: str) -> None:
    body = text(path)
    missing = [needle for needle in needles if needle not in body]
    req(not missing, f'{path} missing dev.282 contract: {missing}')


pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 282, 'dev.282 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 282, 'dev.282 Android version missing')

presenter = text('packages/texture_bridge/lib/src/android_texture_presenter.dart')
for marker in (
    'final bool residentReuse;',
    'Object? _residentKey;',
    'int _presentationRevision = 0;',
    'Object? residentKey,',
    'identical(_residentKey, residentKey)',
    'inFlightBytes: 0,',
    'residentReuse: true,',
    'final presentationRevision = ++_presentationRevision;',
    'presentationRevision == _presentationRevision',
):
    req(marker in presenter, f'texture resident presentation missing: {marker}')
req(presenter.count('_presentationRevision++;') >= 2,
    'resize/release do not invalidate async resident revision')

# Preserve the dev.99 public enum contract rather than broadening an old API
# merely to expose a trace label.
require(
    'packages/media/lib/src/output.dart',
    'enum FramePresentationPath { platform, flutterFallback }',
    'this.platformResidentReuse = false,',
    'final bool platformResidentReuse;',
)
require(
    'packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart',
    'residentKey: this,',
    'path: FramePresentationPath.platform,',
    'platformResidentReuse: sample.residentReuse,',
    "if (event.residentReuse) 'residentReuse': true,",
)
require(
    'packages/sessions/lib/src/upload_session.dart',
    "'presentationPath': platform?.path.name ?? 'unknown'",
    "'platformResidentReuse': platform?.platformResidentReuse ?? false",
)
require(
    'apps/app/lib/debug_trace.dart',
    "event.payload['platformResidentReuse']",
)
require(
    'packages/texture_bridge/test/android_texture_presenter_test.dart',
    'resident output identity skips a redundant platform blit',
    'different output or resize invalidates resident identity',
    'expect(repeated.inFlightBytes, 0);',
    "<String>['create', 'present']",
)

# Surface recreation stays in the platform owner; Dart resident reuse must not
# add a competing Reader/Pipeline lifecycle callback.
require(
    'packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt',
    'override fun onSurfaceAvailable()',
    'scheduleRedraw(this@Output)',
    'fun redraw()',
    'currentFrameAddress',
)

for path in (
    'docs/adr/0261-retained-android-texture-resident-presentation.md',
    'docs/audits/dev282-retained-texture-presentation-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.282 governance file: {path}')

require('docs/ARCHITECTURE.md', 'platformResident', 'OutputFrame identity', 'SurfaceProducer')
require('docs/SPEC.md', 'platformResident', 'RGBA Surface copy')
require('docs/IMPLEMENTATION_STATUS.md', 'presentationIdentity', 'resident surface', 'SurfaceProducer')
require('docs/IMPLEMENTATION_PLAN.md', 'dev.282', 'platformResident', '首次新OutputFrame')
require('CHANGELOG.md', '0.31.0-dev.282', 'resident')

print('PASS: dev.282 retained Android texture resident presentation')
