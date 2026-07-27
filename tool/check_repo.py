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


def check_animated_demo() -> None:
    app = ROOT / 'apps' / 'app'
    index_path = app / 'assets' / 'demo' / 'animated' / 'index.json'
    if not index_path.is_file():
        fail('Animated WebP demo index is missing')
    decoded = json.loads(index_path.read_text(encoding='utf-8'))
    items = decoded.get('items')
    if not isinstance(items, list) or len(items) != 3:
        fail('Animated WebP demo index must contain exactly three fixtures')
    expected = ('animated.webp', 'finite_loop.webp', 'partial_blend.webp')
    seen: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            fail('Animated WebP demo entry must be an object')
        asset = item.get('asset')
        if not isinstance(asset, str):
            fail('Animated WebP demo asset path is invalid')
        name = Path(asset).name
        seen.append(name)
        bundled = app / asset
        native = ROOT / 'native' / 'media_core' / 'testdata' / name
        if not bundled.is_file() or not native.is_file():
            fail(f'Animated WebP fixture is missing: {name}')
        if bundled.read_bytes() != native.read_bytes():
            fail(f'bundled Animated WebP diverges from native fixture: {name}')
        data = bundled.read_bytes()
        if len(data) < 12 or data[:4] != b'RIFF' or data[8:12] != b'WEBP':
            fail(f'invalid bundled WebP header: {name}')
        if item.get('byteLength') != len(data):
            fail(f'Animated WebP byteLength mismatch: {name}')
    if tuple(seen) != expected:
        fail(f'Animated WebP fixtures must stay ordered as {expected}')

    pubspec = (app / 'pubspec.yaml').read_text(encoding='utf-8')
    if 'file_selector: ^1.0.3' not in pubspec:
        fail('local WebP import must use the SDK-compatible file_selector release')
    if '- assets/demo/animated/' not in pubspec:
        fail('Animated WebP assets are not declared in the app pubspec')
    home = (app / 'lib' / 'demo_home.dart').read_text(encoding='utf-8')
    for label in ('100 页静态章节', '内置动图 WebP', '导入本地 WebP'):
        if label not in home:
            fail(f'app demo entry is missing: {label}')
    player = (app / 'lib' / 'webp_demo.dart').read_text(encoding='utf-8')
    for required in ('NativeSourceFactory', 'NativeCursorFactory', 'PixelFrame', 'Image.memory'):
        if required not in player:
            fail(f'Animated WebP player path is incomplete: {required}')


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
    android_native = (ROOT / 'tool/build_android_native.sh').read_text(
        encoding='utf-8'
    )
    android_webp = (ROOT / 'tool/build_webp_android.sh').read_text(
        encoding='utf-8'
    )
    fetch_webp = (ROOT / 'tool/fetch_webp.sh').read_text(encoding='utf-8')
    for required in (
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
        'build_webp_android.sh',
        'jniLibs',
        'libmedia_core.so',
        'COPYING',
        'PATENTS',
    ):
        if required not in android_native:
            fail(f'Android native packaging is incomplete: {required}')
    for required in (
        'android.toolchain.cmake',
        'ANDROID_ABI',
        'BUILD_SHARED_LIBS',
        'WEBP_BUILD_LIBWEBPMUX=OFF',
    ):
        if required not in android_webp:
            fail(f'Android libwebp source build is incomplete: {required}')
    for required in (
        'chromium.googlesource.com/webm/libwebp',
        'WEBP_COMMIT',
        'git -C "$TMP" fetch',
    ):
        lock_or_fetch = fetch_webp + (ROOT / 'native/libwebp.lock').read_text(encoding='utf-8')
        if required not in lock_or_fetch:
            fail(f'pinned libwebp source fetch is incomplete: {required}')
    if 'ZIC_ANDROID_WEBP_ROOT' in android_native or 'ZIC_ANDROID_WEBP_ROOT' in android_build:
        fail('Android native build must not depend on prebuilt libwebp directories')
    if 'build_android_native.sh' not in android_build:
        fail('split APK build must invoke source-built native packaging')
    if 'ZIC_ANDROID_NATIVE=0 ./tool/build_android.sh debug' not in ci:
        fail('Flutter CI must build split debug APKs through tool/build_android.sh')
    if './tool/build_android_native.sh release' not in ci:
        fail('CI must build Android media libraries from pinned libwebp source')
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
    for required in ('CursorBinding', 'CursorStep', 'CursorStepKind', 'PixelFrame'):
        if required not in frame:
            fail(f'frame cursor typing is incomplete: {required}')
    decode = (ROOT / 'packages/sessions/lib/src/decode_session.dart').read_text(
        encoding='utf-8'
    )
    if ' is LoopCursor' in decode or 'Future<FrameRef?> decodeNext()' in frame:
        fail('decode cursor states must be explicit and statically bound')
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
    for required in (
        'required PlaybackCoordinator playback',
        'final PlaybackCoordinator _playback;',
        '_coordinator.reconcile(',
        '_playback.syncPlayback(',
    ):
        if required not in binding:
            fail(f'ReaderBinding capability wiring is incomplete: {required}')
    if 'final playback = _coordinator' in binding or 'is! PlaybackCoordinator' in binding:
        fail('ReaderBinding must not derive playback capability from Coordinator')
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
    media_frame = (ROOT / 'packages/media/lib/src/frame.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'AnimationInfo',
        'CursorBinding',
        'CursorStepKind',
        'LoopCursor',
        'bool rewind()',
    ):
        if required not in media_frame:
            fail(f'animation cursor contract is incomplete: {required}')
    decode_session = (ROOT / 'packages/sessions/lib/src/decode_session.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'DecodeState.ended',
        'CursorStepKind.needMoreData',
        'CursorStepKind.end',
        '_cursor!.loop',
        'TraceEventKind.animationLoop',
    ):
        if required not in decode_session:
            fail(f'decode cursor semantics are incomplete: {required}')
    for forbidden in (' is LoopCursor', 'dynamic '):
        if forbidden in decode_session:
            fail(f'DecodeSession must not use runtime cursor typing: {forbidden}')
    static_demo = (ROOT / 'apps/app/lib/static_demo.dart').read_text(encoding='utf-8')
    if "import 'package:pipeline/pipeline.dart';" not in static_demo:
        fail('static demo must import DecodeTarget from pipeline')
    if 'physicalWidth: 1080' in static_demo or 'physicalHeight: 1920' in static_demo:
        fail('static demo decode target must follow the physical viewport')
    target = (ROOT / 'packages/pipeline/lib/src/decode_target.dart').read_text(
        encoding='utf-8'
    )
    for required in ('DecodeTarget.fit', 'devicePixelRatio', 'maxPhysicalPixels'):
        if required not in target:
            fail(f'adaptive physical decode target is incomplete: {required}')
    webp_demo = (ROOT / 'apps/app/lib/webp_demo.dart').read_text(encoding='utf-8')
    for required in (
        'LayoutBuilder(',
        'cacheWidth: target.physicalWidth',
        'cacheHeight: target.physicalHeight',
        'FramePacing.remaining(',
        '_prepareFollowing(',
    ):
        if required not in webp_demo:
            fail(f'WebP preview scaling/pacing regression: {required}')
    if '_fitDecodeTarget(' in webp_demo or 'const maxSide = 1024' in webp_demo:
        fail('WebP preview must not use a fixed diagnostic decode target')


def check_native_abi() -> None:
    lock = (ROOT / 'native/libwebp.lock').read_text(encoding='utf-8')
    for required in (
        'WEBP_VERSION=1.6.0',
        'WEBP_TAG=v1.6.0',
        'WEBP_COMMIT=4fa21912338357f89e4fd51cf2368325b59e9bd9',
        'WEBP_REPO=https://chromium.googlesource.com/webm/libwebp',
    ):
        if required not in lock:
            fail(f'libwebp source lock is incomplete: {required}')
    rust = (ROOT / 'native/media_core/src/lib.rs').read_text(encoding='utf-8')
    header = (ROOT / 'native/media_core/include/media_core.h').read_text(encoding='utf-8')
    dart = '\n'.join(path.read_text(encoding='utf-8') for path in (ROOT / 'packages/bridge/lib/src').glob('*.dart'))
    for symbol in (
        'zic_abi_version',
        'zic_version',
        'zic_webp_decoder_version',
        'zic_webp_demux_version',
        'zic_source_create',
        'zic_source_free',
        'zic_source_append',
        'zic_source_seal',
        'zic_source_reset',
        'zic_source_len',
        'zic_source_epoch',
        'zic_source_is_sealed',
        'zic_source_kind',
        'zic_cursor_create',
        'zic_cursor_free',
        'zic_cursor_epoch',
        'zic_cursor_decode_next',
        'zic_cursor_frame_count',
        'zic_cursor_loop_count',
        'zic_cursor_metadata_complete',
        'zic_cursor_cycle',
        'zic_cursor_rewind',
        'zic_frame_retain',
        'zic_frame_release',
        'zic_frame_epoch',
        'zic_frame_index',
        'zic_frame_cycle',
        'zic_frame_width',
        'zic_frame_height',
        'zic_frame_duration_us',
        'zic_frame_format',
        'zic_frame_len',
        'zic_frame_data',
    ):
        if symbol not in rust or symbol not in header or symbol not in dart:
            fail(f'ABI symbol is not represented in Rust/header/Dart: {symbol}')
    if 'pub const ABI_VERSION: u32 = 5;' not in rust:
        fail('native ABI version must be 5 for runtime libwebp provenance')
    if 'pub const LIB_VERSION: u32 = 0x0011_0000;' not in rust:
        fail('native library version must identify the adaptive WebP playback release')
    webp_path = ROOT / 'native/media_core/src/webp.rs'
    if not webp_path.is_file():
        fail('native WebP decoder module is missing')
    webp = webp_path.read_text(encoding='utf-8')
    smoke = (ROOT / 'tools/webp_decoder_smoke.c').read_text(encoding='utf-8')
    if 'iter.duration == expected_duration_ms' not in smoke:
        fail('libwebp smoke must validate encoded frame durations')
    for required in (
        'WebPDemuxInternal',
        'WebPDemuxGetFrame',
        'WebPDecodeRGBAInto',
        'iter.0.complete == 0',
        'blend_source_over',
        'dispose_background',
    ):
        if required not in webp:
            fail(f'native WebP decoder is incomplete: {required}')
    fixture = ROOT / 'native/media_core/testdata/animated.webp'
    if not fixture.is_file() or fixture.stat().st_size < 32:
        fail('native Animated WebP fixture is missing or invalid')
    finite_fixture = ROOT / 'native/media_core/testdata/finite_loop.webp'
    if not finite_fixture.is_file() or finite_fixture.stat().st_size < 32:
        fail('finite-loop Animated WebP fixture is missing or invalid')
    build = (ROOT / 'native/media_core/build.rs').read_text(encoding='utf-8')
    for required in ('ZIC_WEBP_LIB_DIR', 'webpdemux', 'webp'):
        if required not in build:
            fail(f'native libwebp link configuration is incomplete: {required}')
    ci = (ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8')
    if 'libwebp-dev' in ci:
        fail('CI must not use distribution prebuilt libwebp development packages')
    for required in ('./tool/test_rust.sh', './tool/check_webp.sh', './tool/build_android_native.sh release'):
        if required not in ci:
            fail(f'CI must build and test pinned libwebp source: {required}')
    version = (ROOT / 'packages/bridge/lib/src/native_version.dart').read_text(encoding='utf-8')
    for required in ('webpDecoderVersion', 'webpDemuxVersion', 'usesPinnedWebp'):
        if required not in version:
            fail(f'native libwebp runtime provenance is incomplete: {required}')
    cursor = (ROOT / 'packages/bridge/lib/src/native_cursor.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'NativeCursorFactory',
        'NativeCursor',
        'NativeFrame',
        'LoopCursor',
        'AnimationInfo',
        'rewind()',
        'retain()',
    ):
        if required not in cursor:
            fail(f'native Dart cursor/frame wrapper is incomplete: {required}')


def main() -> None:
    check_workspace()
    check_manifest()
    check_animated_demo()
    check_names()
    check_dart_sources()
    check_tool_dirs()
    check_compile_regressions()
    check_native_abi()
    print('repository structure: OK')
    print('demo pages: 100')
    print('demo Animated WebP assets: 3')
    print('packages:', ', '.join(EXPECTED_DEPENDENCIES))


if __name__ == '__main__':
    main()
