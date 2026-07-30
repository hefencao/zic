#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import struct
import sys

from check_dart_structure import DartStructureError, check_repository
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

EXPECTED_DEPENDENCIES = {
    'domain': set(),
    'downloads': {
        'catalog', 'domain', 'resource_cache', 'sessions', 'storage',
        'telemetry', 'transport',
    },
    'downloads_bridge': {'downloads', 'runtime_bridge', 'storage_bridge'},
    'catalog': {'domain', 'resource_cache', 'transport'},
    'plugin_host': {'catalog', 'domain'},
    'plugin_host_bridge': {'plugin_host'},
    'resource_cache': set(),
    'telemetry': set(),
    'reader': {'domain', 'telemetry'},
    'pipeline': {'domain', 'telemetry'},
    'media': {'domain', 'transport'},
    'transport': {'domain'},
    'storage': {'catalog', 'domain', 'resource_cache'},
    'storage_bridge': {'catalog', 'resource_cache', 'storage'},
    'sessions': {'domain', 'media', 'pipeline', 'storage', 'telemetry', 'transport'},
    'testkit': {'domain', 'telemetry', 'transport'},
    'bridge': {'media'},
    'texture_bridge': {'bridge'},
    'local_media_bridge': set(),
    'local_media': {'local_media_bridge'},
    'runtime_bridge': set(),
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
        fail('local import must use the SDK-compatible file_selector release')
    if 'file_selector_android:' in pubspec:
        fail('app must not depend on the raw-path Android directory selector implementation')
    if 'local_media:' not in pubspec:
        fail('app must depend on the local_media source package')
    if '- assets/demo/animated/' not in pubspec:
        fail('Animated WebP assets are not declared in the app pubspec')
    home = '\n'.join(
        (app / 'lib' / name).read_text(encoding='utf-8')
        for name in ('demo_home.dart', 'demo_home_views.dart')
    )
    for label in (
        '100 页静态章节',
        'Reader 媒体管线',
        '内置动图 WebP',
        '导入本地 WebP',
        '导入图片文件夹',
    ):
        if label not in home:
            fail(f'app demo entry is missing: {label}')
    player = (app / 'lib' / 'webp_demo.dart').read_text(encoding='utf-8')
    for required in (
        'NativeSourceFactory',
        'NativeCursorFactory',
        'PixelFrame',
        'Image.memory',
        'AndroidTexturePresenter',
        'RendererKind.androidTexture',
    ):
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
        if path.parent == ROOT / 'apps/app/lib' and "import 'dart:io';" in source:
            fail(f'app presentation/composition layer imports dart:io: {path}')
        if 'packages/reader/' in path.as_posix():
            for forbidden in ('File(', '.readAsBytes', 'HttpClient(', 'openRead('):
                if forbidden in source:
                    fail(f'reader UI contains direct I/O ({forbidden}): {path}')
        if path.parent == ROOT / 'apps/app/lib' and path.name.startswith('local_image_'):
            for forbidden in ("import 'dart:io';", 'Directory(', 'RandomAccessFile', 'Isolate.run('):
                if forbidden in source:
                    fail(f'app local-media facade contains platform/file I/O ({forbidden}): {path}')
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
    clean = (ROOT / 'tool/clean.sh').read_text(encoding='utf-8')
    for required in (
        'flutter clean',
        '.dart_tool',
        '.gradle',
        'target',
        '.deps/build',
        '.deps/install',
        'jniLibs',
        'pubspec.lock',
    ):
        if required == 'pubspec.lock':
            if 'pubspec.lock' in clean:
                fail('clean script must preserve dependency lock files')
        elif required not in clean:
            fail(f'project cache clean script is incomplete: {required}')
    for required in (
        'APP="$ROOT/apps/app"',
        '--empty',
        '--platforms=android,ios',
        'cd "$APP"',
    ):
        if required not in bootstrap:
            fail(f'Flutter bootstrap directory/command is incomplete: {required}')
    for required in ('packages/reader', 'packages/local_media_bridge', 'packages/local_media', 'packages/storage_bridge', 'apps/app', 'flutter test test'):
        if required not in flutter_tests:
            fail(f'Flutter test directory is not explicit: {required}')
    for required in ('packages/domain', 'packages/media', 'packages/sessions', 'dart test test'):
        if required not in dart_tests:
            fail(f'Dart test directory is not explicit: {required}')
    for required in ('packages/reader', 'packages/local_media_bridge', 'packages/local_media', 'packages/storage_bridge', 'apps/app', 'flutter analyze'):
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
    for required in (
        '_decodeDemandRevisions',
        '_uploadDemandRevisions',
        'TraceEventKind.decodeStarted',
        'TraceEventKind.uploadStarted',
    ):
        if required not in live:
            fail(f'queued work revision attribution is incomplete: {required}')
    if (
        'follow: true,' not in live
        or 'demandRevision: _uploadDemandRevisions[id] ?? _revision' not in live
    ):
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
    reader_runtime = (ROOT / 'apps/app/lib/reader_runtime.dart').read_text(encoding='utf-8')
    reader_page_identity = (
        ROOT / 'packages/downloads/lib/src/reader_page_identity.dart'
    ).read_text(encoding='utf-8')
    if "import 'package:pipeline/pipeline.dart';" not in reader_runtime:
        fail('Reader runtime must import DecodeTarget from pipeline')
    if 'physicalWidth: 1080' in reader_runtime or 'physicalHeight: 1920' in reader_runtime:
        fail('Reader runtime decode target must follow the physical viewport')
    target = (ROOT / 'packages/pipeline/lib/src/decode_target.dart').read_text(
        encoding='utf-8'
    )
    for required in ('DecodeTarget.fit', 'devicePixelRatio', 'maxPhysicalPixels'):
        if required not in target:
            fail(f'adaptive physical decode target is incomplete: {required}')
    webp_info = (ROOT / 'packages/media/lib/src/webp_info.dart').read_text(
        encoding='utf-8'
    )
    for required in ('parseWebpInfo', "tag == 'VP8X'", "tag == 'VP8 '", "tag == 'VP8L'"):
        if required not in webp_info:
            fail(f'WebP import validation is incomplete: {required}')
    raster = (ROOT / 'packages/pipeline/lib/src/raster_plan.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'final class RasterPlan',
        'isDownsampled',
        'prefersNearestNeighbor',
    ):
        if required not in raster:
            fail(f'codec/display raster separation is incomplete: {required}')
    webp_demo = (ROOT / 'apps/app/lib/webp_demo.dart').read_text(encoding='utf-8')
    for required in (
        'LayoutBuilder(',
        'RasterPlan.fit(',
        'cacheWidth: raster.isDownsampled',
        'FilterQuality.none',
        'WebP 文件无效',
        'FramePacing.remaining(',
        '_prepareFollowing(',
    ):
        if required not in webp_demo:
            fail(f'WebP preview scaling/pacing regression: {required}')
    if '_fitDecodeTarget(' in webp_demo or 'const maxSide = 1024' in webp_demo:
        fail('WebP preview must not use a fixed diagnostic decode target')
    app_test = ROOT / 'apps/app/test'
    smoke = (app_test / 'app_smoke_test.dart').read_text(encoding='utf-8')
    preview_test = (app_test / 'webp_preview_test.dart').read_text(
        encoding='utf-8'
    )
    contract_test = (app_test / 'webp_demo_test.dart').read_text(
        encoding='utf-8'
    )
    image_preview_test = (app_test / 'local_image_preview_test.dart').read_text(
        encoding='utf-8'
    )
    reader_controls_test = (app_test / 'reader_controls_test.dart').read_text(
        encoding='utf-8'
    )
    local_media_test = ROOT / 'packages/local_media/test'
    image_signature_test = (
        local_media_test / 'local_image_signature_test.dart'
    ).read_text(encoding='utf-8')
    image_folder_test = (
        local_media_test / 'local_image_folder_test.dart'
    ).read_text(encoding='utf-8')
    for name, source in (
        ('app_smoke_test.dart', smoke),
        ('webp_preview_test.dart', preview_test),
        ('webp_demo_test.dart', contract_test),
        ('local_image_preview_test.dart', image_preview_test),
        ('reader_controls_test.dart', reader_controls_test),
        ('packages/local_media/test/local_image_signature_test.dart', image_signature_test),
        ('packages/local_media/test/local_image_folder_test.dart', image_folder_test),
    ):
        if 'pump(Duration(' in source or 'pump(const Duration(' in source:
            fail(f'{name} must synchronize on state, not fixed pump durations')
        if 'find.textContaining(' in source:
            fail(f'{name} must not use textContaining as component identity')
        if 'XFile.fromData' in source:
            fail(f'{name} must not depend on XFile.fromData metadata behavior')

    if '_pumpUntilWebpPhase' in smoke or '_pumpUntilImagePhase' in smoke:
        fail('smoke tests must stop at component/state identity, not decoder completion')

    for required in (
        'staticDemoEntryKey',
        'staticDemoScreenKey',
        'mediaPipelineReaderEntryKey',
        'bundledWebpEntryKey',
        'localWebpImportKey',
        'webpPreviewScreenKey',
        'webpPreviewTitleKey',
        'cancelled picker stays on home',
        'Reader entry pushes the media pipeline route',
        'Reader screen hosts the real WebP media component',
        'localImageFolderImportKey',
        'folder reader switches mixed image files by explicit identity',
        'bundled catalog exposes entries by stable identity',
    ):
        if required not in smoke:
            fail(f'smoke navigation boundary is incomplete: {required}')

    for required in (
        'PickedWebp owns its explicit display-name contract',
        'system picker wraps the selected file',
        'system picker preserves cancellation as null',
        'valid local WebP passes container validation',
        'malformed local WebP fails container validation',
        'Reader media identity matches the chapter manifest contract',
        'Reader media player owns the supplied download identity',
        "XFile('/virtual/source-with-unrelated-name')",
    ):
        if required not in contract_test:
            fail(f'picker/validation contract boundary is incomplete: {required}')

    for required in (
        'WebpPreviewStateRegion',
        'WebpPreviewPhase.ready',
        'WebpPreviewPhase.invalid',
        'webpPreviewReadyKey',
        'webpPreviewErrorKey',
        'native pipeline requires explicit confirmation',
        'valid local WebP reaches an explicit ready state',
        'malformed local WebP reaches a controlled invalid state',
        'disposing a WebP player cancels its byte load',
        'preview observer receives the current loading snapshot',
    ):
        if required not in preview_test:
            fail(f'preview state boundary is incomplete: {required}')

    aggregate = (
        ROOT / 'packages/catalog/lib/src/library_comic.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class LibraryComic',
        'required this.sourceId',
        "entry.chapter.sourceId != sourceId",
        r"'${entry.chapter.sourceId}\u0000${entry.chapter.comicId}'",
        'aggregateImportedLibrary',
        'resumeChapter',
        'hasMultipleChapters',
    ):
        if required not in aggregate:
            fail(f'comic-level library aggregate is incomplete: {required}')
    imported_chapter = (
        ROOT / 'packages/catalog/lib/src/imported_chapter.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final String comicTitle',
        'final int sequence',
        "'comicTitle': comicTitle",
        "'sequence': sequence",
        'final List<String> comicAuthors',
        'final String? comicDescription',
        "'comicAuthors': comicAuthors",
    ):
        if required not in imported_chapter:
            fail(f'chapter aggregate metadata is incomplete: {required}')

    home = '\n'.join(
        (ROOT / 'apps/app/lib' / name).read_text(encoding='utf-8')
        for name in ('demo_home.dart', 'demo_home_views.dart', 'home_widgets.dart')
    )
    for required in (
        'typedef WebpPicker = Future<PickedWebp?> Function()',
        'final class PickedWebp',
        'displayName: picked.displayName',
        'WebpPlayerScreen.picked(picked)',
        'final class WebpPreviewState',
        'key: webpPreviewStateKey',
        'key: webpPreviewErrorKey',
    ):
        if required not in webp_demo and required not in home:
            fail(f'local WebP product contract is incomplete: {required}')
    if "_status = 'WebP 文件无效'" in webp_demo:
        fail('preview status must not duplicate the keyed WebP validation error')
    media_load_token = (
        ROOT / 'apps/app/lib/media_load_token.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class MediaLoadToken',
        'Future<void> get whenCancelled',
        'void throwIfCancelled()',
    ):
        if required not in media_load_token:
            fail(f'media byte-load cancellation is incomplete: {required}')
    for required in (
        'typedef WebpLoadToken = MediaLoadToken',
        '_loadToken.cancel()',
        'widget.loadBytes(token)',
        '_notifyPreviewObserver(_previewState)',
        '_scheduleObserverSnapshot()',
    ):
        if required not in webp_demo:
            fail(f'WebP byte-load cancellation is incomplete: {required}')
    if 'this.initialEngine = WebpPlayerEngine.flutter' not in webp_demo:
        fail('WebP pages must use the deterministic Flutter codec until native is explicit')
    for required in (
        'webpNativeConfirmDialogKey',
        'Future<void> _requestEngine(',
        '_setEngine(WebpPlayerEngine.native)',
    ):
        if required not in webp_demo:
            fail(f'native WebP activation is not explicitly quarantined: {required}')
    texture_viewport = (
        ROOT / 'packages/texture_bridge/lib/src/native_texture_viewport.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class NativeTextureViewport',
        'child: AspectRatio(',
        'aspectRatio: aspectRatio',
        'child: Texture(',
    ):
        if required not in texture_viewport:
            fail(f'native texture contain geometry is incomplete: {required}')
    if 'NativeTextureViewport(' not in webp_demo:
        fail('native WebP texture must use aspect-preserving viewport geometry')
    texture_viewport_test = (
        ROOT / 'packages/texture_bridge/test/native_texture_viewport_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'external texture uses contain geometry for a wide source',
        'external texture uses contain geometry for a tall source',
    ):
        if required not in texture_viewport_test:
            fail(f'native texture geometry test is incomplete: {required}')
    for required in (
        'final class PickedImage',
        'class PickedImageFolder',
        'pickLocalImageFolder(',
        'final class LocalImagePlayer',
        'final class ImageFolderScreen',
        "@Deprecated('Use ImageFolderScreen')",
        'imageFolderCurrentFileKey',
        'imageFolderNextKey',
        'ImagePreviewStateRegion',
        'MemoryImage(bytes)',
        'frameBuilder: (context, child, frame, wasSynchronouslyLoaded)',
        'final LocalImageDecodeProbe? decodeProbe',
        'final String sourceId',
        'Future<Uint8List> readAsBytes()',
    ):
        if required not in webp_demo:
            fail(f'local image folder contract is incomplete: {required}')
    if 'provider.resolve(createLocalImageConfiguration(context))' in webp_demo:
        fail('local static images must not resolve a second ImageStream')
    folder_io = (
        ROOT / 'packages/local_media/lib/src/local_image_platform_io.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'recursive: true',
        'detectLocalImageFormat',
        '_headerProbeBytes',
        '_naturalPathCompare',
        'unreadableFiles',
        "selectedUri.scheme.toLowerCase() == 'content'",
        'pickScopedLocalImageDirectory',
        '_androidBridge.readDocument',
        'refreshLocalImageDirectory',
        '_androidBridge.scanImageDirectory',
    ):
        if required not in folder_io:
            fail(f'local image folder enumeration is incomplete: {required}')
    image_types = (
        ROOT / 'packages/local_media/lib/src/local_image_model.dart'
    ).read_text(encoding='utf-8')
    app_folder_facade = (ROOT / 'apps/app/lib/local_image_folder.dart').read_text(
        encoding='utf-8'
    )
    if "export 'package:local_media/local_media.dart';" not in app_folder_facade:
        fail('app local-image facade must export the local_media package')
    for forbidden_path in (
        'local_image_folder_io.dart',
        'local_image_folder_stub.dart',
        'local_image_types.dart',
    ):
        if (ROOT / 'apps/app/lib' / forbidden_path).exists():
            fail(f'app UI layer still owns local-media I/O/model file: {forbidden_path}')
    for required in (
        'enum LocalImageFormat',
        'detectLocalImageFormat',
        "_asciiAt(bytes, 8, 'WEBP')",
        "_startsWithAscii(bytes, 'BM')",
        "0x89, 0x50, 0x4e, 0x47",
        "_startsWithAscii(bytes, 'GIF89a')",
        'LocalImageFormat.png',
        'LocalImageFormat.jpeg',
        'int get unrecognizedFiles',
    ):
        if required not in image_types:
            fail(f'image signature recognition is incomplete: {required}')
    for required in (
        'image signature detector recognizes supported raster families',
        'directory loader recognizes image headers independent of filename',
        'directory refresh rescans an existing filesystem identity',
        'extensionless PNG reaches the generic ready state',
        'directory loader rejects a content URI instead of reporting no images',
        'image observer receives the current loading snapshot',
        'image signature detector rejects truncated container labels',
        'WebP sniffing tolerates metadata or unknown leading chunks',
        'codec probe failure reaches a controlled invalid state',
    ):
        if required not in image_signature_test and required not in image_folder_test and required not in image_preview_test:
            fail(f'local image test boundary is incomplete: {required}')
    local_media_dart = (
        ROOT / 'packages/local_media_bridge/lib/src/local_media_bridge.dart'
    ).read_text(encoding='utf-8')
    local_media_kotlin = (
        ROOT
        / 'packages/local_media_bridge/android/src/main/kotlin/dev/zic/localmedia'
        / 'LocalMediaBridgePlugin.kt'
    ).read_text(encoding='utf-8')
    local_media_format_kotlin = (
        ROOT
        / 'packages/local_media_bridge/android/src/main/kotlin/dev/zic/localmedia'
        / 'LocalMediaFormat.kt'
    ).read_text(encoding='utf-8')
    for required in (
        'pickImageDirectory',
        'scanImageDirectory',
        'readDocument',
        'LocalMediaDirectory',
        'LocalMediaDocument',
        'localMediaBridgeProtocolVersion = 3',
        './tool/clean.sh',
    ):
        if required not in local_media_dart:
            fail(f'local media Dart bridge is incomplete: {required}')
    for required in (
        'Intent.ACTION_OPEN_DOCUMENT_TREE',
        'takePersistableUriPermission',
        'buildChildDocumentsUriUsingTree',
        'withDocumentInputStream(',
        'openTypedAssetFileDescriptor',
        'openAssetFileDescriptor',
        'resolveDirectoryCandidate',
        'readDocument(call, result)',
        'scanImageDirectory(call, result)',
        'headerRecognizedFiles',
        'metadataRecognizedFiles',
        'PROTOCOL_VERSION = 3',
    ):
        if required not in local_media_kotlin:
            fail(f'Android scoped document tree bridge is incomplete: {required}')
    for required in (
        'sniffImageFormat',
        'imageFormatFromMimeType',
        'imageFormatFromDisplayName',
        'ImageFormatResolution',
    ):
        if required not in local_media_format_kotlin:
            fail(f'Android local media format resolution is incomplete: {required}')
    if 'getDirectoryPath' in local_media_kotlin or 'FileUtils.getPathFromUri' in local_media_kotlin:
        fail('Android scoped document tree bridge must not reconstruct raw filesystem paths')

    demo_home = '\n'.join(
        (ROOT / 'apps/app/lib' / name).read_text(encoding='utf-8')
        for name in (
            'demo_home.dart',
            'demo_home_views.dart',
            'home_widgets.dart',
            'home_library_session.dart',
        )
    )
    if 'super.key,' not in demo_home:
        fail('_DemoCard must accept and forward stable semantic keys')
    if "import 'package:bridge/bridge.dart' show parseWebpInfo;" not in contract_test:
        fail('WebP validation tests must import their public parser contract directly')
    for required in (
        'TraceEventKind.frameDecoded',
        'TraceEventKind.frameUploaded',
        'TraceEventKind.framePresented',
        'TraceEventKind.taskFailed',
        'TextureTelemetryContext(',
        'demandRevision: widget.demandRevision?.call()',
        'widget.downloadIdentity ??',
        "'decodeMicros'",
        "'prepareMicros'",
        "'deadlineMissMicros'",
    ):
        if required not in webp_demo:
            fail(f'Reader media telemetry attribution is incomplete: {required}')
    image_base_declaration = (
        "final base = slash < 0 ? normalized : normalized.substring(slash + 1);"
    )
    if webp_demo.count(image_base_declaration) != 1:
        fail('imageDisplayName must declare its basename exactly once')
    if 'int get revision => pipeline.revision;' not in binding:
        fail('ReaderBinding must expose the applied demand revision to media output')

    reader_view = (ROOT / 'packages/reader/lib/src/reader_view.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'typedef ReaderPageBuilder',
        'final ReaderPageBuilder? pageBuilder',
        '_ReaderPageHost',
        'reportFirstFrame',
        'InteractiveViewer(',
        'maxScale: 5',
        'onPointerDown: _handlePointerDown',
        'onPointerUp: _handlePointerUp',
        '_singleTapTimer',
        'NeverScrollableScrollPhysics',
        'rotationQuarterTurns',
    ):
        if required not in reader_view:
            fail(f'Reader media integration seam is incomplete: {required}')
    for required in (
        'MediaPipelineReaderScreen',
        'chapter_media_pipeline.json',
        'NativeWebpPlayer(',
        'ReaderRuntimeScreen(',
        'traceSessionId: runtime.sessionId',
        'demandRevision: runtime.demandRevision',
        'downloadIdentity: readerPageDownloadId(runtime.chapter, asset)',
    ):
        if required not in static_demo:
            fail(f'Reader media pipeline route is incomplete: {required}')
    if "import 'package:downloads/downloads.dart'" not in static_demo:
        fail('static_demo.dart must import the Reader page identity adapter')

    for required in (
        'DownloadId readerPageDownloadId(',
        'ReaderTraceIdentity readerPageTraceIdentity(',
        'sourceRevision: chapter.chapter.sourceRevision',
        'resourceKeyPrefix: download.key',
    ):
        if required not in reader_page_identity:
            fail(f'Reader page identity adapter is incomplete: {required}')
    artifact_cache_transport = (
        ROOT / 'packages/downloads/lib/src/artifact_cache_transport.dart'
    ).read_text(encoding='utf-8')
    promoted_read_pool = (
        ROOT / 'packages/downloads/lib/src/promoted_artifact_read_pool.dart'
    ).read_text(encoding='utf-8')
    promoted_read_pool_test = (
        ROOT / 'packages/downloads/test/promoted_artifact_read_pool_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class PromotedArtifactReadPool',
        'Future<Uint8List?> read(DownloadId id)',
        'Future<Uint8List?> join(DownloadId id)',
        'void observe(DownloadSession session)',
        'void release(DownloadId id)',
    ):
        if required not in promoted_read_pool:
            fail(f'promoted artifact read coalescing is incomplete: {required}')
    for required in (
        'readPool.cache',
        "'consumer': 'session-copy'",
        '_chunkedBytes(body)',
        '_fnv64String(id.key)',
        "'fallback': 'origin'",
    ):
        if required not in artifact_cache_transport:
            fail(f'artifact cache transport cold-open path is incomplete: {required}')
    for required in (
        'page consumer and session transport share one promoted read',
        'terminal replacement session releases the shared encoded read',
        'failed cache reads are not retained',
        'joining does not initiate a cache read',
    ):
        if required not in promoted_read_pool_test:
            fail(f'promoted read pool regression is incomplete: {required}')

    cold_open_test_path = ROOT / 'apps/app/test/reader_artifact_cold_open_test.dart'
    if not cold_open_test_path.is_file():
        fail('Reader cold promoted-artifact regression is missing')
    cold_open_test = cold_open_test_path.read_text(encoding='utf-8')
    for required in (
        'cold Reader consumes promoted bytes before replacement session staging',
        'expect(store.reads, 1)',
        'expect(originLoads, 0)',
    ):
        if required not in cold_open_test:
            fail(f'Reader cold promoted-artifact regression is incomplete: {required}')

    chapter_downloads = (
        ROOT / 'packages/downloads/lib/src/chapter_downloads.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'abstract interface class ManagedChapterDownloadService',
        'ChapterDownloadService,',
        'ArtifactCacheMaintenance,',
        'ArtifactCacheStore {}',
        'implements ManagedChapterDownloadService',
    ):
        if required not in chapter_downloads:
            fail(f'Managed chapter artifact capability is incomplete: {required}')

    for required in (
        'final class ReaderRuntimeScreen',
        'LoaderTransport(widget.loaderSources)',
        'SystemUiMode.immersiveSticky',
        'readerBottomControlsKey',
        'readerPageSliderKey',
        'readerPauseKey',
        'readerSpeedKey',
        'readerRotateKey',
        'readerFavoriteKey',
        'readerDownloadKey',
        'ReaderPlaybackController',
        'playback: _playback',
        'IconThemeData(color: Colors.white)',
        'DefaultTextStyle.merge',
        'Future<void> _downloadChapter()',
        "'consumer': 'reader-direct'",
        'PromotedArtifactReadPool',
        "'fallback': 'session'",
    ):
        if required not in reader_runtime:
            fail(f'Reader runtime identity/transport path is incomplete: {required}')
    for required in (
        'reader starts immersive and exposes complete bottom controls',
        'readerTopControlsKey',
        'readerBottomControlsKey',
        'readerPageSliderKey',
        'readerPauseKey',
        'readerSpeedKey',
        'readerRotateKey',
        'readerFavoriteKey',
        'readerDownloadKey',
    ):
        if required not in reader_controls_test:
            fail(f'Reader controls regression coverage is incomplete: {required}')
    if 'playback: runtime.playback' not in static_demo:
        fail('Reader media pipeline must receive pause/speed playback state')
    for required in (
        'playback: widget.playback!',
        'targetWidth: raster.isDownsampled',
        'targetHeight: raster.isDownsampled',
        'allowUpscaling: false',
        'preservePresentedFrame: identical(oldWidget.bytes, widget.bytes)',
        'TraceEventKind.decodeStarted',
        'TraceEventKind.frameDecoded',
        'TraceEventKind.framePresented',
    ):
        if required not in webp_demo:
            fail(f'controlled animated playback regressed: {required}')
    local_image_preview_test = (
        ROOT / 'apps/app/test/local_image_preview_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'Flutter animated codec exposes cold first-frame phases',
        'Flutter target rebuild keeps the presented frame visible',
        'expect(find.byType(RawImage), findsOneWidget)',
    ):
        if required not in local_image_preview_test:
            fail(f'Flutter cold-decode regression is incomplete: {required}')
    asset_transport_path = ROOT / 'apps/app/lib/asset_bundle_transport.dart'
    asset_transport_test_path = (
        ROOT / 'apps/app/test/asset_bundle_transport_test.dart'
    )
    if not asset_transport_test_path.is_file():
        fail('AssetBundle transport tests are missing')
    asset_transport = asset_transport_path.read_text(encoding='utf-8')
    for required in (
        'final class AssetBundleTransport',
        'rangeSupported: true',
        'validators.matches(currentValidators)',
    ):
        if required not in asset_transport:
            fail(f'AssetBundle transport is incomplete: {required}')
    for required in (
        'LiveCoordinator(',
        'DownloadRegistry(',
        'EphemeralCacheWorkspace.readerSession(',
        'layout: _workspace.layout',
        '_workspace.readArtifact(',
        'await _workspace.dispose()',
        'addSnapshotListener(listener)',
        '_binding?.detach(',
        'AssetBundleTransport(rootBundle)',
        'LoaderTransport(widget.loaderSources)',
    ):
        if required not in reader_runtime:
            fail(f'Reader live artifact path is incomplete: {required}')
    if 'FakeCoordinator(' in static_demo or 'FakeCoordinator(' in reader_runtime:
        fail('Reader app runtime must not use the fake coordinator')
    imported_chapter = (
        ROOT / 'packages/catalog/lib/src/imported_chapter.dart'
    ).read_text(encoding='utf-8')
    loader_transport = (
        ROOT / 'packages/transport/lib/src/loader_transport.dart'
    ).read_text(encoding='utf-8')
    ephemeral_workspace = (
        ROOT / 'packages/storage/lib/src/ephemeral_workspace.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ImportedChapterRecord',
        'ChapterManifest toManifest()',
        'Map<String, Object?> toJson()',
        'factory ImportedChapterRecord.fromJson',
        'String get stablePageId',
        'pageId: page.stablePageId',
    ):
        if required not in imported_chapter:
            fail(f'Imported chapter catalog record is incomplete: {required}')
    for required in (
        'final class LoaderTransport',
        'bool contains(Uri uri)',
        'rangeSupported: true',
        'validators.matches(currentValidators)',
        '_fnv64Bytes(bytes)',
    ):
        if required not in loader_transport:
            fail(f'Platform byte-loader transport is incomplete: {required}')
    for required in (
        'final class EphemeralCacheWorkspace',
        'CacheLayout(rootPath)',
        'Future<Uint8List> readArtifact',
        'Future<void> dispose()',
    ):
        if required not in ephemeral_workspace:
            fail(f'Reader storage workspace is incomplete: {required}')
    for required in (
        'imageFolderChapterRecord',
        'ReaderRuntimeScreen(',
        'LoaderTransportSource(',
        'tokenBytesLoader:',
        'reader.requestPage(',
        'downloadIdentity: readerPageDownloadId(runtime.chapter, asset)',
        'traceSessionId: runtime.sessionId',
        'demandRevision: runtime.demandRevision',
    ):
        if required not in webp_demo:
            fail(f'Folder import is not integrated with Reader: {required}')
    if 'final class ImageFolderScreen extends StatefulWidget' in webp_demo:
        fail('Folder import must not retain the standalone manual-index reader')

    imported_library = (
        ROOT / 'packages/catalog/lib/src/imported_library_store.dart'
    ).read_text(encoding='utf-8')
    sqlite_imported_library = (
        ROOT / 'packages/storage/lib/src/sqlite_imported_library_store.dart'
    ).read_text(encoding='utf-8')
    storage_bridge = (
        ROOT / 'packages/storage_bridge/lib/storage_bridge.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'abstract interface class ImportedLibraryStore',
        'final class MemoryImportedLibraryStore',
        'Future<void> saveProgress(ReadingProgress progress)',
        'reconcileImportedProgress',
    ):
        if required not in imported_library:
            fail(f'imported library contract is incomplete: {required}')
    for required in (
        'final class SqliteImportedLibraryStore',
        'CREATE TABLE imported_chapter',
        'CREATE TABLE reading_progress',
        'ON DELETE CASCADE',
    ):
        if required not in sqlite_imported_library:
            fail(f'durable imported library storage is incomplete: {required}')
    for required in (
        'getApplicationSupportDirectory()',
        'imported_library.sqlite3',
        'SqliteImportedLibraryStore(',
    ):
        if required not in storage_bridge:
            fail(f'Flutter storage path bridge is incomplete: {required}')
    for required in (
        'ImportedImageChapterScreen(',
        'refreshPickedImageFolder',
        'initialProgress:',
        'onProgressChanged:',
        'readLocalImageSource(',
        'mediaFormat: image.format.name',
    ):
        if required not in webp_demo:
            fail(f'persistent local chapter Reader path is incomplete: {required}')
    for required in (
        '_library.upsertChapter(record)',
        '_library.saveProgress',
        'ImportedImageChapterScreen(',
        '_buildHorizontalComics(',
        'ComicCoverCard(',
    ):
        if required not in demo_home:
            fail(f'imported library UI integration is incomplete: {required}')
    for forbidden in (
        '_buildImportedLibraryMaintenance',
        '_refreshImportedChapter',
        'importedChapterRefreshKey',
        'importedChapterRemoveKey',
    ):
        if forbidden in demo_home:
            fail(f'home still exposes local directory maintenance: {forbidden}')
    for required in (
        'this.initialProgress',
        'this.onProgressChanged',
        '_handleReaderProgress',
        'ReaderMode.continuous',
    ):
        if required not in reader_runtime:
            fail(f'Reader progress restoration is incomplete: {required}')

    app_pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(
        encoding='utf-8'
    )
    for required in (
        'storage:',
        'storage_bridge:',
        'transport:',
    ):
        if required not in app_pubspec:
            fail(f'Reader app runtime dependency is missing: {required}')
    download_session = (
        ROOT / 'packages/sessions/lib/src/download_session.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'typedef DownloadSnapshotListener',
        'void addSnapshotListener(',
        'void removeSnapshotListener(',
        'void _notifySnapshot()',
    ):
        if required not in download_session:
            fail(f'Download promotion observation is incomplete: {required}')
    for required in (
        'void detach(String sessionId)',
        'DemandDiff.between(previous, empty)',
    ):
        if required not in binding:
            fail(f'Reader binding lifecycle cleanup is incomplete: {required}')

    texture = (
        ROOT / 'packages/texture_bridge/lib/src/android_texture_presenter.dart'
    ).read_text(encoding='utf-8')
    kotlin = (
        ROOT
        / 'packages/texture_bridge/android/src/main/kotlin/dev/zic/texture'
        / 'TextureBridgePlugin.kt'
    ).read_text(encoding='utf-8')
    android_rust = (
        ROOT / 'native/media_core/src/android_texture.rs'
    ).read_text(encoding='utf-8')
    cursor = (ROOT / 'packages/bridge/lib/src/native_cursor.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'TextureFrameOwner retain()',
        'final retained = frame.retain()',
        'retained.dispose()',
        "'frameHandle': retained.handleAddress",
        'deadlineAfterMicros',
        'TextureTelemetryContext',
        'sessionId',
        'decodeIdentity',
        'demandRevision',
        'epoch',
        'TexturePresentTelemetry',
        'TextureFallbackTelemetry',
        'frameBytes',
        'textureBytes',
        'inFlightBytes',
    ):
        if required not in texture:
            fail(f'Android texture ownership/telemetry is incomplete: {required}')
    for required in (
        'createSurfaceProducer()',
        'newSingleThreadExecutor',
        'NativeBlitter.retain',
        'NativeBlitter.blit',
        'NativeBlitter.release',
        'onSurfaceAvailable',
        'onSurfaceCleanup',
        'scheduleRedraw',
        'producer.scheduleFrame()',
        'synchronized(lifecycleLock)',
        'scheduleProducerFrame',
        'mainHandler.post',
        'canSchedule: () -> Boolean',
        'val isReleased: Boolean',
        'resizeProducer',
        'releaseProducer',
        'retainedFrameBytes',
        'queueMicros',
        'uploadMicros',
        'deadlineMissMicros',
    ):
        if required not in kotlin:
            fail(f'Android serial blit lane is incomplete: {required}')
    for required in (
        'Java_dev_zic_texture_NativeBlitter_retain',
        'Java_dev_zic_texture_NativeBlitter_release',
        'Java_dev_zic_texture_NativeBlitter_blit',
        'ANativeWindow_lock',
        'ANativeWindow_unlockAndPost',
        'copy_premultiplied_rgba',
    ):
        if required not in android_rust:
            fail(f'native Android blit implementation is incomplete: {required}')
    if 'int get handleAddress' not in cursor:
        fail('NativeFrame must expose an opaque retained handle to presenters')

    preferences = (
        ROOT / 'packages/catalog/lib/src/library_preferences.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'enum ComicSourceKind',
        'enum LibrarySortMode',
        'final class LibraryCategory',
        'final class ComicPreference',
        'final class ChapterReadState',
        'final class ComicSourcePreference',
    ):
        if required not in preferences:
            fail(f'library preference contract is incomplete: {required}')
    store = (
        ROOT / 'packages/storage/lib/src/sqlite_imported_library_store.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'const _schemaVersion = 6',
        'PRAGMA user_version = $_schemaVersion',
        'PRIMARY KEY(source_id, chapter_id)',
        'PRIMARY KEY(source_id, comic_id)',
        'library_migration_issue',
        'listMigrationIssues',
        'acknowledgeMigrationIssues',
        'acknowledged_us',
        'saved_comic',
        'upsertSavedComic',
        'library_category',
        'comic_preference',
        'chapter_read_state',
        'comic_source_preference',
        'saveComicPreference',
        'saveChapterReadState',
        'saveSourcePreference',
    ):
        if required not in store:
            fail(f'durable bookshelf storage is incomplete: {required}')
    diagnostics = (
        ROOT / 'apps/app/lib/library_diagnostics.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class LibraryDiagnosticsScreen',
        'libraryDiagnosticsEntryKey',
        'libraryDiagnosticsCopyKey',
        'libraryDiagnosticsAcknowledgeAllKey',
        'includeAcknowledged: _includeAcknowledged',
        'acknowledgeMigrationIssues',
    ):
        if required not in diagnostics:
            fail(f'library migration diagnostics are incomplete: {required}')

    for required in (
        'WHERE source_id = ? AND comic_id = ?',
        'WHERE source_id = ? AND chapter_id = ?',
        'ON p.source_id = c.source_id AND p.chapter_id = c.chapter_id',
        'schemaFrom: fromVersion',
        'PRAGMA foreign_key_check',
    ):
        if required not in store:
            fail(f'source-composite library storage is incomplete: {required}')
    migration = (
        ROOT / 'packages/catalog/lib/src/comic_source_migration.dart'
    ).read_text(encoding='utf-8')
    app_home = (ROOT / 'apps/app/lib/demo_home.dart').read_text(encoding='utf-8')
    for required in (
        'ComicPreference mergePreference',
        'existingTarget?.customOrder',
        '...migrated.categoryIds',
        '...?existingTarget?.categoryIds',
    ):
        if required not in migration:
            fail(f'cross-source preference merge is incomplete: {required}')
    for required in (
        'final prepared = <_PreparedChapterMigration>[]',
        'targetProgress: targetEntry?.progress',
        'targetReadState: targetReadStates',
        'final mergedPreference = plan.mergePreference',
    ):
        if required not in app_home:
            fail(f'cross-source migration preflight is incomplete: {required}')

    source_contract = (
        ROOT / 'packages/catalog/lib/src/source_catalog.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'abstract interface class BrowsableComicSource',
        'Future<SourceBrowsePage> browse',
        'Future<Uint8List> loadResource',
        'final class ComicSourceDescriptor',
    ):
        if required not in source_contract:
            fail(f'comic source browsing contract is incomplete: {required}')
    mangadex = (
        ROOT / 'packages/catalog/lib/src/mangadex_source.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class MangaDexSource',
        "Uri.https('api.mangadex.org'",
        "'/at-home/server/$chapterId'",
        'translatedLanguage[]',
        'contentRating[]',
        'maxNetworkAttempts',
        'connectionTimeout: const Duration(seconds: 15)',
    ):
        if required not in mangadex:
            fail(f'MangaDex test source is incomplete: {required}')
    source_ui = (ROOT / 'apps/app/lib/source_browser.dart').read_text(
        encoding='utf-8',
    )
    for required in (
        'final class ComicSourcesPage',
        'final class SourceManagementScreen',
        'final class SourceComicDetailsScreen',
        'sourceManagementScreenKey',
        'comicSourceSwitcherKey',
        'ReorderableListView.builder',
        'ChoiceChip(',
        'SelectableText(',
        'comicSourceCopyErrorKey',
        'Clipboard.setData',
        "lower.contains('failed host lookup')",
    ):
        if required not in source_ui:
            fail(f'comic source UI is incomplete: {required}')
    configure_platforms = ROOT / 'tool/configure_platforms.py'
    configure_platforms_test = ROOT / 'tool/test_configure_platforms.py'
    run_android = ROOT / 'tool/run_android.sh'
    if not all(
        path.is_file()
        for path in (configure_platforms, configure_platforms_test, run_android)
    ):
        fail('generated Flutter host configuration scripts are missing')
    configure_text = configure_platforms.read_text(encoding='utf-8')
    for required in (
        'android.permission.INTERNET',
        'AndroidManifest.xml',
        'already configured',
    ):
        if required not in configure_text:
            fail(f'Android host configuration is incomplete: {required}')
    for script_name in ('bootstrap_platforms.sh', 'build_android.sh', 'run_android.sh'):
        script = (ROOT / 'tool' / script_name).read_text(encoding='utf-8')
        if 'configure_platforms.py' not in script:
            fail(f'{script_name} must configure the generated Android host')

    details_ui = (ROOT / 'apps/app/lib/comic_details.dart').read_text(
        encoding='utf-8',
    )
    demo_home = (ROOT / 'apps/app/lib/demo_home.dart').read_text(
        encoding='utf-8',
    )
    reader_navigation_test = (
        ROOT / 'packages/reader/test/reader_navigation_test.dart'
    ).read_text(encoding='utf-8')
    if "import 'package:domain/domain.dart';" not in demo_home:
        fail('demo_home.dart must import Comic and Chapter from domain')
    if 'tester.doubleTap(' in reader_navigation_test:
        fail('Reader gesture test must use SDK-compatible real tap events')
    if 'Duration(milliseconds: 400)' not in reader_navigation_test:
        fail('Reader double-tap test must drain the app-owned tap window')
    for required in (
        'final class LocalComicDetailsScreen',
        'final class RemoteComicDetailsScreen',
        'ComicDetailsRouteKind resolveComicDetailsRoute',
        'final class ComicDetailsLibrarySnapshot',
        'final class _ComicDetailsScaffold',
        'final class _ComicDetailsHeader',
        'final class _ComicChapterList',
        'RefreshIndicator(',
        'AlwaysScrollableScrollPhysics',
        'comicDetailsReadKey(',
        'comicDetailsDownloadKey(',
        'final class _ReadSwipeAction',
        'onHorizontalDragEnd:',
        '恢复未读',
        'ensureSourceChapter',
        'persistComic',
        'reloadLibrary(refreshContent:',
        'SelectableText(failure.details)',
        'comicDetailsRetryKey',
        'await _setRead(entry, true)',
        'Future<Uint8List>.sync',
    ):
        if required not in details_ui:
            fail(f'local/remote comic details UI is incomplete: {required}')
    saved_comic = (
        ROOT / 'packages/catalog/lib/src/saved_comic.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class SavedComicRecord',
        'final class SavedChapterRecord',
        'SavedComicRecord.fromManifest',
        "'chapters': chapters.map",
    ):
        if required not in saved_comic:
            fail(f'comic-level durable metadata is incomplete: {required}')
    downloads = (ROOT / 'packages/downloads/lib/src/chapter_downloads.dart').read_text(
        encoding='utf-8',
    )
    for required in (
        'enum ChapterDownloadPhase',
        'final class ChapterDownloadSnapshot',
        'abstract interface class ChapterDownloadService',
        'Stream<ChapterDownloadSnapshot> get changes',
        'Future<void> retry(',
        'Future<void> cancel(',
        'Future<void> delete(',
        'Future<ChapterDownloadSnapshot> inspect(',
        'final class MemoryChapterDownloadService',
        'final class PersistentChapterDownloadService',
        'ChapterPageLoader',
        '_chapters[_identity(entry)]',
        'DownloadJob(',
        'DownloadState.promoted',
        'offline_chapters',
        '_terminalPhases',
    ):
        if required not in downloads:
            fail(f'durable chapter download service is incomplete: {required}')
    download_manager_path = ROOT / 'apps/app/lib/download_manager.dart'
    if not download_manager_path.is_file():
        fail('download management surface is missing')
    download_manager = download_manager_path.read_text(encoding='utf-8')
    for required in (
        'final class DownloadManagerScreen',
        'downloadManagerCancelKey',
        'downloadManagerRetryKey',
        'downloadManagerDeleteKey',
        'LinearProgressIndicator(',
        'snapshot.receivedBytes',
        'snapshot.totalBytes',
        'SelectableText(',
        'Clipboard.setData',
    ):
        if required not in download_manager:
            fail(f'download management surface is incomplete: {required}')
    migration = (
        ROOT / 'packages/catalog/lib/src/comic_source_migration.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ComicSourceMigrationPlan',
        'ChapterMigrationConfidence',
        'migratePreference',
    ):
        if required not in migration:
            fail(f'comic source migration contract is incomplete: {required}')

    home_path = ROOT / 'apps/app/lib/demo_home.dart'
    home = '\n'.join(
        path.read_text(encoding='utf-8')
        for path in (
            home_path,
            ROOT / 'apps/app/lib/demo_home_views.dart',
            ROOT / 'apps/app/lib/home_widgets.dart',
            ROOT / 'apps/app/lib/home_library_session.dart',
        )
    )
    if len(home_path.read_text(encoding='utf-8').splitlines()) > 1800:
        fail('demo_home.dart exceeded the first-stage decomposition budget')
    for required in (
        "part 'demo_home_views.dart';",
        'HomeLibrarySession(',
        'ResourceCacheCoordinator',
        'CachedBrowsableComicSource',
    ):
        if required not in home:
            fail(f'home composition contract is incomplete: {required}')
    for forbidden_path in (
        ROOT / 'apps/app/lib/cover_cache.dart',
        ROOT / 'apps/app/lib/reader_page_cache.dart',
        ROOT / 'apps/app/lib/chapter_downloads.dart',
        ROOT / 'apps/app/lib/whole_comic_downloads.dart',
    ):
        if forbidden_path.exists():
            fail(f'cache policy must not live in app composition: {forbidden_path.name}')
    resource_cache = (
        ROOT / 'packages/resource_cache/lib/src/resource_cache.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ResourceCacheManager',
        'ResourceCacheKind.imageBytes',
        'ResourceCacheKind.comicDetails',
        'ResourceCacheKind.chapterMetadata',
        'ResourceCacheKind.searchResults',
        'namespace',
        'globalMaxWeight',
        '_generations',
        '_epoch',
        'invalidateNamespace(',
        '_enforceBudgets(',
        'abstract interface class ResourceCacheByteStore',
        'ResourceCacheByteStoreMaintenance',
        '_readPersistent(',
        '_writePersistent(',
        'inspectPersistentBytes()',
        'abstract interface class ResourceCacheByteStoreFileAccess',
        'getOrLoadEncodedImage(',
        'FileEncodedResourceSource',
    ):
        if required not in resource_cache:
            fail(f'unified resource cache contract is incomplete: {required}')
    for required in (
        'final value = bytes as T;',
        'final maintenance = store as ResourceCacheByteStoreMaintenance;',
    ):
        if required not in resource_cache:
            fail(f'dev.38 resource cache compile closure is missing: {required}')

    transition_analysis = (
        ROOT / 'packages/telemetry/lib/src/reader_transition_analysis.dart'
    ).read_text(encoding='utf-8')
    transition_analysis_test = (
        ROOT / 'packages/telemetry/test/reader_transition_analysis_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ReaderTransitionTraceAnalyzer',
        'final int workRevision;',
        "'transitionRevision': revision",
        'firstFrameReadyBeforeTransition',
        'hostRemountedAfterTransition',
        'dominantMeasuredPhase',
        'presentedForFirstFrame',
        'final Duration? artifactRead;',
        'final Duration? artifactJoin;',
        'final String? artifactConsumer;',
        "event.payload['consumer'] == 'reader-direct'",
    ):
        if required not in transition_analysis:
            fail(f'Reader transition replay is incomplete: {required}')
    for required in (
        'derives deterministic transition phase durations',
        'recognizes a neighboring page ready before the midpoint',
        'reports origin fallback and host remount evidence',
        'analyzeAll separates rapid-swipe revisions and pages',
        "expect(analysis.workRevision, 3)",
        "expect(analysis.artifactConsumer, 'reader-direct')",
        "expect(analysis.toJson()['artifactReadMicros'], 30)",
        "expect(analysis.toJson()['artifactJoinMicros'], 7)",
    ):
        if required not in transition_analysis_test:
            fail(f'Reader transition replay regression is incomplete: {required}')

    reader_view = (
        ROOT / 'packages/reader/lib/src/reader_view.dart'
    ).read_text(encoding='utf-8')
    for required in (
        "'reader-page-host:${chapter.pages[index].assetKey}'",
        'required this.demandRevision',
        'TraceEventKind.pageTransition',
        'TraceEventKind.pageHostMounted',
        'TraceEventKind.pageHostDisposed',
        'super.key,',
    ):
        if required not in reader_view:
            fail(f'stable Reader host attribution is incomplete: {required}')

    storage_bridge = (
        ROOT / 'packages/storage_bridge/lib/storage_bridge.dart'
    ).read_text(encoding='utf-8')
    if 'ResourceCacheCoordinator createAppResourceCache(' not in storage_bridge:
        fail('production durable response cache composition is not centralized')

    cached_source = (
        ROOT / 'packages/catalog/lib/src/cached_comic_source.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class CachedBrowsableComicSource',
        'loadCachedSourceImage(',
        'loadCachedComicImage(',
        'invalidateComicResourceCache(',
        'ResourceCacheKind.searchResults',
        'ResourceCacheKind.comicDetails',
        'ResourceCacheKind.chapterMetadata',
        'Future<Uint8List> loadResource(Uri uri) => source.loadResource(uri)',
    ):
        if required not in cached_source:
            fail(f'catalog cache adapter is incomplete: {required}')
    durable_response_store = (
        ROOT / 'packages/storage/lib/src/file_resource_cache_byte_store.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class FileResourceCacheByteStore',
        'ResourceCacheFileByteStore,',
        'ResourceCacheByteStoreMaintenance',
        'Future<ResourceCacheByteStoreUsage> inspect()',
        'Future<ResourceCacheByteStoreTrimReport> trimTo(',
        'contentHash',
        'lastAccessedAt',
        'Future<PersistedResourceFile?> locate(',
        '_pendingTouches',
    ):
        if required not in durable_response_store:
            fail(f'durable response byte store is incomplete: {required}')

    runtime_limits = (
        ROOT / 'packages/plugin_host/lib/src/runtime_limits.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ExternalPluginRuntimeLimits',
        'void validate()',
        'invocationTimeout <= Duration.zero',
    ):
        if required not in runtime_limits:
            fail(f'external plugin runtime limits are incomplete: {required}')

    runtime_protocol = (
        ROOT / 'packages/plugin_host/lib/src/runtime_protocol.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'enum ExternalPluginRuntimeOperation',
        'final class ExternalPluginRuntimeRequest',
        'final class ExternalPluginRuntimeResponse',
        'final class ExternalPluginRuntimeSourceDescriptor',
        'abstract interface class ExternalPluginRuntimeConnection',
        'static const int schemaVersion = 1',
        'Uint8List',
    ):
        if required not in runtime_protocol:
            fail(f'external plugin runtime protocol is incomplete: {required}')
    for forbidden_import in (
        "package:reader/",
        "package:downloads/",
        "package:sessions/",
        "package:pipeline/",
    ):
        if forbidden_import in runtime_protocol:
            fail(f'external plugin runtime protocol leaks {forbidden_import}')

    runtime_channel = (
        ROOT / 'packages/plugin_host/lib/src/runtime_channel.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'abstract interface class ExternalPluginRuntimeMessageChannel',
        'final class ExternalPluginRuntimeHandshake',
        'final class MessageChannelExternalPluginRuntimeConnection',
        'request.toMessage()',
        'ExternalPluginRuntimeResponse.fromMessage(raw)',
        'Future<void>? _closeFuture',
    ):
        if required not in runtime_channel:
            fail(f'external plugin runtime channel is incomplete: {required}')
    for forbidden_import in (
        "package:reader/",
        "package:downloads/",
        "package:sessions/",
        "package:pipeline/",
    ):
        if forbidden_import in runtime_channel:
            fail(f'external plugin runtime channel leaks {forbidden_import}')

    runtime_adapter = (
        ROOT / 'packages/plugin_host/lib/src/runtime_source_adapter.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ExternalPluginRuntimeSession',
        'implements ExternalComicPluginSession',
        'implements BrowsableComicSource',
        'maxConcurrentInvocations',
        'maxResponseBytes',
        'operation.timeout(limits.invocationTimeout)',
        'Future<Uint8List> loadResource(Uri uri)',
    ):
        if required not in runtime_adapter:
            fail(f'external plugin runtime adapter is incomplete: {required}')

    runtime_executors = (
        ROOT / 'packages/plugin_host/lib/src/runtime_executors.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class MihonExecutionRequest',
        'abstract interface class MihonIsolatedRuntimeBackend',
        'Future<ExternalPluginRuntimeConnection> activate(',
        'final class MihonIsolatedExecutor',
        'final class VeneraExecutionRequest',
        'abstract interface class VeneraSandboxRuntimeBackend',
        'final class VeneraSandboxExecutor',
        'ExternalPluginRuntimeSession(',
        'payloadSha256',
        'supportsLimits',
    ):
        if required not in runtime_executors:
            fail(f'external plugin execution contract is incomplete: {required}')

    payload_inspectors = (
        ROOT / 'packages/plugin_host/lib/src/payload_inspectors.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class MihonApkInspector',
        'abstract interface class MihonApkMetadataReader',
        'final class VeneraJavaScriptInspector',
        'sha256.bind(file.openRead())',
        'Venera repository key does not match script metadata',
    ):
        if required not in payload_inspectors:
            fail(f'external plugin payload inspection is incomplete: {required}')

    app_main = (ROOT / 'apps/app/lib/main.dart').read_text(encoding='utf-8')
    for required in (
        'runApp(const _BootstrapApp())',
        "const _StartupApp()",
        'openImportedLibraryStore(root)',
    ):
        if required not in app_main:
            fail(f'cold-start composition is incomplete: {required}')
    chapter_downloads = (
        ROOT / 'packages/downloads/lib/src/chapter_downloads.dart'
    ).read_text(encoding='utf-8')
    open_body = chapter_downloads.split(
        'static Future<PersistentChapterDownloadService> open', 1
    )[1].split('final DownloadRegistry _registry', 1)[0]
    if 'restoreIndexed()' in open_body:
        fail('persistent chapter service eagerly restores every artifact at startup')
    if 'materializedSessionCount' not in chapter_downloads:
        fail('persistent chapter service lacks lazy-restore diagnostics')
    for required in (
        'Future<List<ChapterDownloadSnapshot>> inspectMany(',
        'for (final record in await _index.list()) record.key: record',
        'indexedRecords: indexed',
    ):
        if required not in chapter_downloads:
            fail(f'bulk index-only download projection is incomplete: {required}')

    home_library_session = (
        ROOT / 'apps/app/lib/home_library_session.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'library.listAllChapterReadStates()',
        'chapterDownloads.inspectMany(requested)',
    ):
        if required not in home_library_session:
            fail(f'Home startup bulk projection is incomplete: {required}')

    external_plugin_catalog = (
        ROOT / 'packages/catalog/lib/src/external_plugin_catalog.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'parseMihonExtensionIndex(',
        'parseVeneraSourceIndex(',
        "json['fileName']",
        "json['key']",
        "sourceId: 'venera:$externalKey'",
        'abstract interface class ExternalComicPluginHost',
        'abstract interface class ExternalComicPluginSession',
    ):
        if required not in external_plugin_catalog:
            fail(f'external plugin catalog boundary is incomplete: {required}')

    plugin_gate = '\n'.join(
        path.read_text(encoding='utf-8')
        for path in sorted((ROOT / 'packages/plugin_host/lib/src').glob('*.dart'))
    )
    for required in (
        'final class PermissionedExternalComicPluginHost',
        'abstract interface class ExternalPluginInspector',
        'abstract interface class ExternalPluginExecutor',
        'ExternalPluginDenial.signerNotTrusted',
        'ExternalPluginDenial.unsupportedAbi',
        'ExternalPluginDenial.capabilityDenied',
        'MemoryExternalPluginQuarantine',
        'final class ExternalPluginRuntimeRegistry',
        'ExternalPluginDenial.sourceIdentityCollision',
        '_validateSession(',
    ):
        if required not in plugin_gate:
            fail(f'external plugin host gate is incomplete: {required}')

    cache_maintenance = (
        ROOT / 'packages/resource_cache/lib/src/resource_cache_maintenance.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ResourceCacheCoordinator',
        'final ResourceCacheManager responses',
        'final ArtifactCacheMaintenance? artifacts',
        'Future<ResourceCacheUsage> inspect()',
        'ResourceCacheMaintenancePolicy',
        'Future<ResourceCacheMaintenanceReport> trim()',
        'Future<ResourceCacheMaintenanceReport> clear()',
    ):
        if required not in cache_maintenance:
            fail(f'unified cache coordinator contract is incomplete: {required}')

    chapter_downloads = (ROOT / 'packages/downloads/lib/src/chapter_downloads.dart').read_text(encoding='utf-8')
    for required in (
        'ArtifactCacheMaintenance',
        'CacheOps(',
        'inspectArtifacts()',
        'Map<String, List<Uint8List?>> _chapters',
        'pages[index] = bytes',
        '_storedPageCount(',
        '_storedPageBytes(',
    ):
        if required not in chapter_downloads:
            fail(f'artifact cache maintenance contract is incomplete: {required}')
    reader_view = (ROOT / 'packages/reader/lib/src/reader_view.dart').read_text(encoding='utf-8')
    for required in (
        "'zoom:${chapter.pages[index].assetKey}'",
        "'reader-page-host:${chapter.pages[index].assetKey}'",
        'void didUpdateWidget(covariant _ZoomableReaderPage oldWidget)',
    ):
        if required not in reader_view:
            fail(f'Reader stable page-host contract is incomplete: {required}')
    for forbidden in (
        'ReaderPageBytesCache',
        '_schedulePageWarmup(',
        'allowImplicitScrolling: true',
    ):
        if forbidden in reader_runtime or forbidden in reader_view:
            fail(f'Reader must not bypass pipeline demand with UI prefetch: {forbidden}')
    if "package:resource_cache/resource_cache.dart" in reader_runtime or \
            "package:resource_cache/resource_cache.dart" in reader_view:
        fail('Reader presentation must not depend on response-cache policy')
    app_lib = '\n'.join(
        path.read_text(encoding='utf-8')
        for path in (ROOT / 'apps/app/lib').glob('*.dart')
    )
    if 'ResourceCacheKey(' in app_lib:
        fail('Presentation must request cached catalog resources through package adapters')
    if 'String? _managedComicId;' in home:
        fail('bookshelf management selection must use source-aware comic identity')

    for required in (
        'homeUpdatesSectionKey',
        'homeHistorySectionKey',
        'NavigationBar(',
        'SegmentedButton<_SourceFilter>',
        'showSelectedIcon: false',
        'showCheckmark: false',
        '_ShelfViewMode',
        'bookshelfViewKey',
        'Draggable<String>',
        'DragTarget<String>',
        'ReorderableListView.builder',
        '_addComicsToSelectedCategory',
        '_moveComicToCategory',
        'bookshelfBatchBarKey',
        'bookshelfBatchMoveKey',
        'comicMoveKey(String sourceId, String comicId)',
        'comicReorderKey(String sourceId, String comicId)',
        '_managedComicIdentities',
        '_startBatchSelection',
        '_comicMovePopup',
        'if (_manageShelf && !_batchManagement)',
        'ComicDownloadProgress.active',
        'ComicDownloadProgress.offline',
        'aggregateImportedLibrary(',
        'savedComics: _savedComics',
        'comicCoverKey(String sourceId, String comicId)',
        'comic.identity',
        'final LibraryComic comic',
        '_sourcePageVisited',
        'ComicSourcesPage(',
        'comicSourceManageKey',
        "label: const Text('漫画源管理')",
        'downloadManagerEntryKey',
        'DownloadManagerScreen(',
        '_downloadProgressForComic',
        '_DownloadWatermark',
        '_wholeComicDownloads',
        '_downloadComicEntries',
        '_openingComicIdentities',
        '_CoverTitleGradient',
        'Future<EncodedResourceSource>.sync(widget.loader)',
        'encodedResourceImageProvider(source)',
        '_selectSourceMigrationTarget',
        "label: const Text('搜索同名作品')",
        "throw StateError('目标漫画源返回了不匹配的漫画或章节身份')",
        "throw StateError('目标漫画源返回了不匹配的章节详情身份')",
        "label: '漫画源'",
    ):
        if required not in home:
            fail(f'Android library UI slice is incomplete: {required}')

    for forbidden in (
        '_buildManagementBar(',
        '_openMoveComicSheet(',
        'bookshelfManagementBarKey',
        '_managedComicIdentity',
        '_CategoryPopup(',
    ):
        if forbidden in home:
            fail(f'obsolete single-comic management UI remains: {forbidden}')

    details = (ROOT / 'apps/app/lib/comic_details.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'comicDetailsDownloadAllKey',
        'ComicDetailsChapterDownloadInspector',
        'downloadChanges.listen',
        'ChapterDownloadSnapshot',
        'color: Theme.of(context).colorScheme.surface',
        "label: const Text('下载整本')",
        '_readingProgressLabel',
    ):
        if required not in details:
            fail(f'comic details download/status contract is incomplete: {required}')

    download_manager = (ROOT / 'apps/app/lib/download_manager.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'snapshot.title',
        'snapshot.phase != ChapterDownloadPhase.complete',
        'LinearProgressIndicator(',
        'WholeComicDownloadQueue',
        'downloadQueuePolicyKey',
        'wholeComicQueuePauseKey',
        'wholeComicQueueResumeKey',
        'WholeComicNetworkPolicy.unmetered',
        'WholeComicPowerPolicy.charging',
    ):
        if required not in download_manager:
            fail(f'download manager presentation is incomplete: {required}')

    whole_queue = (ROOT / 'packages/downloads/lib/src/whole_comic_downloads.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'final class WholeComicDownloadQueue',
        'WholeComicQueuePhase.waitingForPolicy',
        'completedChapterIdentities',
        '_policyAllowsWork()',
        '_cancelActiveForJob',
        'WholeComicQueuePolicy',
        'ChapterDownloadService',
    ):
        if required not in whole_queue:
            fail(f'durable whole-comic queue is incomplete: {required}')

    downloads_bridge = (
        ROOT / 'packages/downloads_bridge/lib/src/downloads_bridge.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class PlatformWholeComicQueueEnvironment',
        'final class JsonWholeComicQueueStore',
        'openPersistentWholeComicDownloadQueue',
        'RuntimeEnvironmentBridge',
        'readJsonObjectFile',
    ):
        if required not in downloads_bridge:
            fail(f'download platform adapter is incomplete: {required}')

    runtime_bridge = (
        ROOT / 'packages/runtime_bridge/lib/src/runtime_bridge.dart'
    ).read_text(encoding='utf-8')
    runtime_plugin = (
        ROOT
        / 'packages/runtime_bridge/android/src/main/kotlin/dev/zic/runtime/RuntimeBridgePlugin.kt'
    ).read_text(encoding='utf-8')
    runtime_manifest = (
        ROOT / 'packages/runtime_bridge/android/src/main/AndroidManifest.xml'
    ).read_text(encoding='utf-8')
    for required in (
        'runtimeBridgeProtocolVersion',
        'RuntimeEnvironmentSnapshot',
        'currentEnvironment',
        'receiveBroadcastStream()',
    ):
        if required not in runtime_bridge:
            fail(f'runtime environment Dart bridge is incomplete: {required}')
    for required in (
        'registerDefaultNetworkCallback',
        'isActiveNetworkMetered',
        'BatteryManager.EXTRA_STATUS',
        'PROTOCOL_VERSION',
    ):
        if required not in runtime_plugin:
            fail(f'runtime environment Android bridge is incomplete: {required}')
    if 'android.permission.ACCESS_NETWORK_STATE' not in runtime_manifest:
        fail('runtime environment Android bridge lacks network-state permission')

    reader_runtime = (ROOT / 'apps/app/lib/reader_runtime.dart').read_text(
        encoding='utf-8'
    )
    for required in (
        'void _togglePlaybackPaused()',
        'onPressed: _togglePlaybackPaused',
        'ValueListenableBuilder<ReaderPlaybackState>',
        'Future<void> _choosePlaybackSpeed()',
        'SimpleDialog(',
        'SimpleDialogOption(',
        'readerSpeedOptionKey',
    ):
        if required not in reader_runtime:
            fail(f'Reader playback controls are incomplete: {required}')

    chapter_download_tests = '\n'.join(
        path.read_text(encoding='utf-8')
        for path in (
            ROOT / 'packages/downloads/test/chapter_downloads_test.dart',
            ROOT / 'apps/app/test/chapter_downloads_test.dart',
        )
    )
    for required in (
        'memory download publishes progress and delete returns to idle',
        'memory download cancellation keeps partial progress and retry completes',
        'download manager exposes completed task and durable delete',
        'download manager pauses and resumes a whole-comic queue job',
    ):
        if required not in chapter_download_tests:
            fail(f'download lifecycle regression coverage is incomplete: {required}')

    whole_queue_tests = '\n'.join(
        path.read_text(encoding='utf-8')
        for path in (
            ROOT / 'packages/downloads/test/whole_comic_downloads_test.dart',
            ROOT / 'packages/downloads_bridge/test/downloads_bridge_test.dart',
        )
    )
    for required in (
        'whole-comic queue enforces configured chapter concurrency',
        'whole-comic queue waits for policy and resumes on environment change',
        'policy loss suspends an active chapter and resumes it later',
        'paused whole-comic job survives queue recreation',
        'JSON queue adapter restores policy and pending chapters',
    ):
        if required not in whole_queue_tests:
            fail(f'whole-comic queue regression coverage is incomplete: {required}')


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
    if 'pub const LIB_VERSION: u32 = 0x0012_0300;' not in rust:
        fail('native library version must identify the explicit picker-name repair release')
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
    for required in ('ZIC_WEBP_LIB_DIR', 'webpdemux', 'webp', 'rustc-link-lib=android'):
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


def check_current_iteration() -> None:
    resource_cache = (
        ROOT / 'packages/resource_cache/lib/src/resource_cache.dart'
    ).read_text(encoding='utf-8')
    response_store = (
        ROOT / 'packages/storage/lib/src/file_resource_cache_byte_store.dart'
    ).read_text(encoding='utf-8')
    home = (ROOT / 'apps/app/lib/home_widgets.dart').read_text(encoding='utf-8')
    telemetry = (
        ROOT / 'packages/telemetry/lib/src/home_startup.dart'
    ).read_text(encoding='utf-8')
    bridge = (
        ROOT
        / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/PluginHostBridgePlugin.kt'
    ).read_text(encoding='utf-8')
    for required in (
        'ENTRY_CLASS_KEYS',
        'entryClasses',
        'tachiyomi.extension.class',
    ):
        if required not in bridge:
            fail(f'Mihon APK entry metadata bridge is incomplete: {required}')
    for required in (
        'enum EncodedResourceOrigin',
        'abstract interface class ResourceCacheFileByteStore',
        'if (store is! ResourceCacheFileByteStore)',
    ):
        if required not in resource_cache:
            fail(f'dev.43 encoded-resource compile closure is incomplete: {required}')
    for required in (
        "response-manifest-v1.json",
        '_pendingTouches',
        'FileSystemEntityType.file',
    ):
        if required not in response_store:
            fail(f'dev.43 durable response manifest is incomplete: {required}')
    for required in (
        'HomeStartupTelemetry',
        'coverSourceReady',
        'coverFirstFrame',
    ):
        if required not in home or required not in telemetry:
            fail(f'dev.43 Home startup attribution is incomplete: {required}')
    for required in (
        'Executors.newSingleThreadExecutor',
        'getPackageArchiveInfo',
        'apkContentsSigners',
        'tachiyomix.extensionLib',
    ):
        if required not in bridge:
            fail(f'dev.43 Mihon Android metadata bridge is incomplete: {required}')
    for forbidden in ('DexClassLoader', 'PathClassLoader', 'Class.forName'):
        if forbidden in bridge:
            fail(f'Mihon inspection must not load extension code: {forbidden}')


    runtime_worker = (
        ROOT / 'packages/plugin_host/lib/src/runtime_worker.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ExternalPluginRuntimeWorker',
        'abstract interface class ExternalPluginRuntimeDriver',
        'final class ExternalPluginRuntimeCancellationToken',
        "code: 'duplicate-request'",
        "code: 'unknown-source'",
        'invocation.cancellation._cancel()',
        'await _driver.close()',
        'WorkerBackedExternalPluginRuntimeMessageChannel',
    ):
        if required not in runtime_worker:
            fail(f'dev.47 isolated runtime worker is incomplete: {required}')

    runtime_channel = (
        ROOT / 'packages/plugin_host/lib/src/runtime_channel.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'CancellableExternalPluginRuntimeMessageChannel',
        'implements CancellableExternalPluginRuntimeConnection',
        'return channel.cancel(requestId)',
    ):
        if required not in runtime_channel:
            fail(f'dev.47 runtime cancellation channel is incomplete: {required}')

    runtime_platform = (
        ROOT / 'packages/plugin_host_bridge/lib/src/method_channel_runtime_backends.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'AndroidMihonIsolatedRuntimeBackend',
        'AndroidVeneraSandboxRuntimeBackend',
        'ExternalPluginRuntimeServiceMethods.activateMihon',
        'ExternalPluginRuntimeServiceMethods.activateVenera',
        'ExternalPluginRuntimeServiceMethods.invoke',
        'ExternalPluginRuntimeServiceMethods.cancel',
        'ExternalPluginRuntimeServiceMethods.closeSession',
        "'processId': processId",
    ):
        if required not in runtime_platform:
            fail(f'dev.47 platform runtime channel is incomplete: {required}')

    for source, label in (
        (runtime_worker, 'runtime worker'),
        (runtime_platform, 'platform runtime channel'),
    ):
        for forbidden_import in (
            'package:reader/',
            'package:downloads/',
            'package:sessions/',
            'package:pipeline/',
        ):
            if forbidden_import in source:
                fail(f'dev.47 {label} leaks {forbidden_import}')

    for required in (
        'RUNTIME_CHANNEL_NAME',
        'runtime-backend-unavailable',
        'runtime-session-missing',
    ):
        if required not in bridge:
            fail(f'dev.47 Android runtime bridge is incomplete: {required}')

    image_player = (ROOT / 'apps/app/lib/webp_demo.dart').read_text(
        encoding='utf-8'
    )
    image_test = (
        ROOT / 'apps/app/test/local_image_preview_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'abstract interface class FlutterAnimatedCodec',
        'typedef FlutterAnimatedCodecFactory',
        'instantiateFlutterAnimatedCodec',
        'localImageDirectFileProvider',
        'WidgetsBinding.instance.endOfFrame',
        'oldWidget.codecFactory != widget.codecFactory',
    ):
        if required not in image_player:
            fail(f'dev.48 image lifecycle seam is incomplete: {required}')
    for required in (
        "test('plain local image uses a file provider without byte loading'",
        'final class _TestFlutterAnimatedCodec',
        'await _unmountAsyncImage(tester)',
        'finally {',
    ):
        if required not in image_test:
            fail(f'dev.48 image regression cleanup is incomplete: {required}')
    if 'rootBundle.load' in image_test:
        fail('dev.48 controlled-codec tests must not depend on engine WebP decode')


    runtime_activation = (
        ROOT / 'packages/plugin_host/lib/src/runtime_activation.dart'
    ).read_text(encoding='utf-8')
    runtime_activation_test = (
        ROOT / 'packages/plugin_host/test/runtime_activation_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'sealed class ExternalPluginRuntimeActivationEnvelope',
        'FileExternalPluginRuntimePayloadVerifier',
        'ExternalPluginRuntimeVerifiedPayload',
        'ExternalPluginRuntimeProcessHost',
        'payload-identity-mismatch',
        'source-identity-mismatch',
        'await temporary.rename(promoted.path)',
        'await _activationTail',
        '_closingSessions',
    ):
        if required not in runtime_activation:
            fail(f'dev.49 process-entry runtime ownership is incomplete: {required}')
    for forbidden_import in (
        'package:reader/',
        'package:downloads/',
        'package:sessions/',
        'package:pipeline/',
    ):
        if forbidden_import in runtime_activation:
            fail(f'dev.49 process runtime leaks {forbidden_import}')
    for required in (
        'process entry stages and revalidates the exact approved payload',
        'payload mutation is rejected before a driver is created',
        'process restart has no sessions and never replays a request',
    ):
        if required not in runtime_activation_test:
            fail(f'dev.49 runtime activation regression is incomplete: {required}')

    runtime_service = (
        ROOT / 'packages/plugin_host/lib/src/runtime_service.dart'
    ).read_text(encoding='utf-8')
    runtime_service_test = (
        ROOT / 'packages/plugin_host/test/runtime_service_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class ExternalPluginRuntimeServiceEndpoint',
        'abstract final class ExternalPluginRuntimeServiceMethods',
        "'processId': processId",
        "code: 'runtime-process-mismatch'",
        'ExternalPluginRuntimeActivationEnvelope.fromMessage',
        '_processHost.closeSession',
        '_processHost.cancel',
    ):
        if required not in runtime_service:
            fail(f'dev.50 runtime service endpoint is incomplete: {required}')
    for required in (
        'service endpoint owns activation invoke cancel and close routing',
        'Venera activation uses the same service endpoint contract',
        'new service process rejects an old process generation',
        'activation method must match the payload ecosystem',
        'process close is joinable and rejects later activation',
    ):
        if required not in runtime_service_test:
            fail(f'dev.50 runtime service regression is incomplete: {required}')
    for forbidden_import in (
        'package:reader/',
        'package:downloads/',
        'package:sessions/',
        'package:pipeline/',
    ):
        if forbidden_import in runtime_service:
            fail(f'dev.50 runtime service leaks {forbidden_import}')

    runtime_service_handler = (
        ROOT / 'packages/plugin_host_bridge/lib/src/runtime_service_handler.dart'
    ).read_text(encoding='utf-8')
    runtime_service_handler_test = (
        ROOT / 'packages/plugin_host_bridge/test/runtime_service_handler_test.dart'
    ).read_text(encoding='utf-8')
    for required in (
        'final class AndroidExternalPluginRuntimeServiceHandler',
        '_channel.setMethodCallHandler(dispatch)',
        'await _endpoint.handle(call.method, call.arguments)',
        'on ExternalPluginRuntimeServiceException',
        'on ExternalPluginRuntimeProcessException',
        'await _endpoint.close()',
    ):
        if required not in runtime_service_handler:
            fail(f'dev.50 Android runtime service handler is incomplete: {required}')
    for required in (
        'handler delegates raw methods to the process endpoint',
        'handler maps stale generations to a stable platform error',
        'detach closes the process and is joinable',
    ):
        if required not in runtime_service_handler_test:
            fail(f'dev.50 runtime service handler regression is incomplete: {required}')

    for required in (
        'Uint8List _largeCanvasWebp()',
        'decodeTargets',
        'target != decodeTargets.first',
    ):
        if required not in image_test:
            fail(f'dev.49 meaningful target rebuild regression is incomplete: {required}')


def main() -> None:
    try:
        dart_files, dart_tests = check_repository(ROOT)
    except DartStructureError as error:
        fail(str(error))
    check_workspace()
    check_manifest()
    check_animated_demo()
    check_names()
    check_dart_sources()
    check_tool_dirs()
    check_compile_regressions()
    check_current_iteration()
    check_native_abi()
    print('repository structure: OK')
    print(f'Dart structure: {dart_files} files, {dart_tests} test files')
    print('demo pages: 100')
    print('demo Animated WebP assets: 3')
    print('packages:', ', '.join(EXPECTED_DEPENDENCIES))


if __name__ == '__main__':
    main()
