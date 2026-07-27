#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

EXPECTED_DEPENDENCIES = {
    'domain': set(),
    'catalog': {'domain'},
    'telemetry': set(),
    'reader': {'domain', 'telemetry'},
    'pipeline': {'domain', 'telemetry'},
    'media': {'domain', 'transport'},
    'transport': {'domain'},
    'storage': {'domain'},
    'sessions': {'domain', 'media', 'pipeline', 'storage', 'telemetry', 'transport'},
    'testkit': {'domain', 'telemetry', 'transport'},
    'bridge': {'media'},
}


def fail(message: str) -> None:
    print(f'ERROR: {message}', file=sys.stderr)
    raise SystemExit(1)


def pubspec_name(path: Path) -> str:
    source = path.read_text(encoding='utf-8')
    match = re.search(r'^name:\s*([^\s#]+)', source, flags=re.M)
    if match is None:
        fail(f'{path} has no package name')
    return match.group(1)


def pubspec_list(path: Path, section: str) -> list[str]:
    values: list[str] = []
    active = False
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.startswith(' ') and line.rstrip() == f'{section}:':
            active = True
            continue
        if active and line and not line.startswith(' '):
            break
        if active:
            match = re.match(r'^\s{2}-\s+([^\s#]+)', line)
            if match is not None:
                values.append(match.group(1))
    return values


def pubspec_dependency_names(path: Path) -> set[str]:
    names: set[str] = set()
    active = False
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.startswith(' ') and line.rstrip() == 'dependencies:':
            active = True
            continue
        if active and line and not line.startswith(' '):
            break
        if active:
            match = re.match(r'^\s{2}([A-Za-z0-9_]+):', line)
            if match is not None:
                names.add(match.group(1))
    return names


def check_workspace() -> None:
    members = pubspec_list(ROOT / 'pubspec.yaml', 'workspace')
    if not members:
        fail('root workspace is missing')
    names: set[str] = set()
    for member in members:
        path = ROOT / member
        if not path.is_dir():
            fail(f'workspace member does not exist: {member}')
        name = pubspec_name(path / 'pubspec.yaml')
        if name in names:
            fail(f'duplicate package name: {name}')
        names.add(name)

    internal_names = set(EXPECTED_DEPENDENCIES)
    for package_name, allowed in EXPECTED_DEPENDENCIES.items():
        package_path = ROOT / 'packages' / package_name
        if not package_path.is_dir():
            fail(f'missing package: {package_name}')
        deps = pubspec_dependency_names(package_path / 'pubspec.yaml')
        internal = deps & internal_names
        if internal != allowed:
            fail(
                f'{package_name} internal dependencies {sorted(internal)} '
                f'!= expected {sorted(allowed)}'
            )


def check_manifest() -> None:
    app = ROOT / 'apps' / 'app'
    manifest_path = app / 'assets' / 'demo' / 'chapter_001.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    pages = manifest.get('pages')
    if not isinstance(pages, list) or len(pages) != 100:
        fail('demo chapter must contain exactly 100 pages')
    chapter = manifest.get('chapter')
    if not isinstance(chapter, dict) or chapter.get('pageCount') != len(pages):
        fail('manifest pageCount mismatch')
    for index, page in enumerate(pages):
        if page.get('index') != index:
            fail(f'page index mismatch at {index}')
        asset_path = app / page['uri']
        if not asset_path.is_file():
            fail(f'missing page asset: {asset_path}')
        if page.get('byteLength') != asset_path.stat().st_size:
            fail(f'byteLength mismatch: {asset_path}')
        with asset_path.open('rb') as handle:
            header = handle.read(24)
        if header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
            fail(f'invalid PNG header: {asset_path}')
        width, height = struct.unpack('>II', header[16:24])
        if width != page.get('width') or height != page.get('height'):
            fail(f'PNG dimensions mismatch: {asset_path}')


DART_RESERVED_PACKAGE_NAMES = {'library'}


def check_names() -> None:
    for path in ROOT.glob('packages/*/pubspec.yaml'):
        name = pubspec_name(path)
        if name.startswith('zic_'):
            fail(f'unnecessary project prefix in package name: {name}')
        if name in DART_RESERVED_PACKAGE_NAMES:
            fail(f'reserved Dart package name: {name}')
    for path in ROOT.rglob('*.dart'):
        source = path.read_text(encoding='utf-8')
        match = re.search(r'\bZic[A-Z][A-Za-z0-9_]*\b', source)
        if match is not None:
            fail(f'unnecessary project prefix {match.group(0)} in {path.relative_to(ROOT)}')


def check_dart_sources() -> None:
    for path in ROOT.rglob('*.dart'):
        source = path.read_text(encoding='utf-8')
        if '\t' in source:
            fail(f'tab character in {path.relative_to(ROOT)}')
        if 'MethodChannel' in source and 'packages/bridge/' in path.as_posix():
            fail('native bridge must not transport frame bytes through MethodChannel')
        if 'packages/reader/' in path.as_posix():
            for forbidden in ('File(', '.readAsBytes', 'HttpClient(', 'openRead('):
                if forbidden in source:
                    fail(f'reader UI contains direct I/O ({forbidden}): {path}')
        stripped = re.sub(
            r"//.*?$|/\*.*?\*/|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"",
            '',
            source,
            flags=re.M | re.S,
        )
        for opening, closing in [('(', ')'), ('[', ']'), ('{', '}')]:
            if stripped.count(opening) != stripped.count(closing):
                fail(f'unbalanced {opening}{closing} in {path.relative_to(ROOT)}')



def check_tool_dirs() -> None:
    bootstrap = (ROOT / 'tool/bootstrap_platforms.sh').read_text(encoding='utf-8')
    flutter_tests = (ROOT / 'tool/test_flutter.sh').read_text(encoding='utf-8')
    dart_tests = (ROOT / 'tool/test_dart.sh').read_text(encoding='utf-8')
    analyze = (ROOT / 'tool/analyze.sh').read_text(encoding='utf-8')
    android_build = (ROOT / 'tool/build_android.sh').read_text(encoding='utf-8')
    ci = (ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8')
    for required in (
        'APP="$ROOT/apps/app"',
        '--empty',
        '--platforms=android,ios',
        'cd "$APP"',
    ):
        if required not in bootstrap:
            fail(f'Flutter bootstrap directory/command is incomplete: {required}')
    for required in ('packages/reader', 'apps/app', 'flutter test test'):
        if required not in flutter_tests:
            fail(f'Flutter test directory is not explicit: {required}')
    for required in ('packages/domain', 'packages/media', 'packages/sessions', 'dart test test'):
        if required not in dart_tests:
            fail(f'Dart test directory is not explicit: {required}')
    for required in ('packages/reader', 'apps/app', 'flutter analyze'):
        if required not in analyze:
            fail(f'Flutter analyze directory is not explicit: {required}')
    for required in ('APP="$ROOT/apps/app"', '--split-per-abi', 'flutter build apk'):
        if required not in android_build:
            fail(f'Android split APK build is incomplete: {required}')
    if './tool/build_android.sh debug' not in ci:
        fail('CI must build split debug APKs through tool/build_android.sh')
    if 'flutter build apk --debug' in ci:
        fail('CI must not build a single fat debug APK')

def check_compile_regressions() -> None:
    live = (ROOT / 'packages/sessions/lib/src/live_coordinator.dart').read_text(
        encoding='utf-8'
    )
    if "import 'download_session.dart';" not in live:
        fail('LiveCoordinator must import its DownloadSession annotation')
    retry = (ROOT / 'packages/sessions/lib/src/retry_policy.dart').read_text(
        encoding='utf-8'
    )
    for forbidden in (
        'assert(!baseDelay.isNegative)',
        'assert(!maxDelay.isNegative)',
    ):
        if forbidden in retry:
            fail(f'const RetryPolicy contains non-constant assertion: {forbidden}')
    frame = (ROOT / 'packages/media/lib/src/frame.dart').read_text(
        encoding='utf-8'
    )
    if "import 'source.dart';" not in frame:
        fail('frame.dart must import the EncodedSource contract')
    artifact = (ROOT / 'packages/storage/lib/src/artifact.dart').read_text(
        encoding='utf-8'
    )
    if 'return await reader.read(length < maxBytes ? length : maxBytes);' not in artifact:
        fail('Artifact.readPrefix must await the read before closing its file handle')
    if 'preparedDepth: uploads?.preparedDepth(id) ?? 0' not in live:
        fail('ready uploaded output must contribute to the decode watermark')
    if 'decode.follow(' not in live:
        fail('source wake-up must queue a decode successor without cancelling active work')
    if '_submitUpload(sessionId, id, demand, follow: true);' not in live:
        fail('decode wake-up must coalesce upload work without replacing active upload')
    lane = (ROOT / 'packages/sessions/lib/src/net_lane.dart').read_text(
        encoding='utf-8'
    )
    if 'bool follow({' not in lane or '_core.follow(' not in lane:
        fail('task lanes must support non-cancelling follow-up work')
    native_source = (ROOT / 'packages/bridge/lib/src/native_source.dart').read_text(
        encoding='utf-8'
    )
    if re.search(r'\),\s*\];', native_source):
        fail('native source index expressions must not contain a trailing comma')
    pipeline = (ROOT / 'packages/pipeline/lib/pipeline.dart').read_text(
        encoding='utf-8'
    )
    if "export 'src/viewport_phase.dart';" not in pipeline:
        fail('pipeline must export viewport playback phases')
    sessions = (ROOT / 'packages/sessions/lib/sessions.dart').read_text(
        encoding='utf-8'
    )
    if "export 'src/playback_gate.dart';" not in sessions:
        fail('sessions must export PlaybackGate')
    if 'void syncPlayback(' not in live or '_playbackGate.apply(' not in live:
        fail('LiveCoordinator must integrate viewport playback gating')
    viewport_test = (ROOT / 'packages/pipeline/test/viewport_phase_test.dart').read_text(
        encoding='utf-8'
    )
    if 'ReadingDirection.leftToRight' in viewport_test or 'lefttoright' in viewport_test:
        fail('viewport tests must use the ReadingDirection.ltr abbreviation')
    binding = (ROOT / 'packages/sessions/lib/src/reader_binding.dart').read_text(
        encoding='utf-8'
    )
    if '_coordinator.reconcile(' not in binding or 'playback.syncPlayback(' not in binding:
        fail('ReaderBinding must drive both demand and viewport playback')
    media_output = (ROOT / 'packages/media/lib/src/output.dart').read_text(
        encoding='utf-8'
    )
    if 'int get byteLength;' not in media_output:
        fail('OutputFrame must expose byteLength for output budgeting')
    budget = (ROOT / 'packages/sessions/lib/src/frame_budget.dart').read_text(
        encoding='utf-8'
    )
    for required in ('currentDecodedReserve', 'currentOutputReserve', 'FrameBudgeter'):
        if required not in budget:
            fail(f'frame budget implementation is incomplete: {required}')


def check_native_abi() -> None:
    rust = (ROOT / 'native/media_core/src/lib.rs').read_text(encoding='utf-8')
    header = (ROOT / 'native/media_core/include/media_core.h').read_text(encoding='utf-8')
    dart = '\n'.join(path.read_text(encoding='utf-8') for path in (ROOT / 'packages/bridge/lib/src').glob('*.dart'))
    for symbol in (
        'zic_abi_version',
        'zic_version',
        'zic_source_create',
        'zic_source_free',
        'zic_source_append',
        'zic_source_seal',
        'zic_source_reset',
        'zic_source_len',
        'zic_source_epoch',
        'zic_source_is_sealed',
        'zic_source_kind',
    ):
        if symbol not in rust or symbol not in header or symbol not in dart:
            fail(f'ABI symbol is not represented in Rust/header/Dart: {symbol}')


def main() -> None:
    check_workspace()
    check_manifest()
    check_names()
    check_dart_sources()
    check_tool_dirs()
    check_compile_regressions()
    check_native_abi()
    print('repository structure: OK')
    print('demo pages: 100')
    print('packages:', ', '.join(EXPECTED_DEPENDENCIES))


if __name__ == '__main__':
    main()
