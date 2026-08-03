#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.96 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains rejected dev.96 tokens: {found}')


require(
    'packages/bridge/lib/src/native_decode_pool.dart',
    '_nativeDecodeWorkerCount = 2',
    'Future<void> prewarm()',
    '_currentPending',
    '_nonCurrentPending',
    'nonCurrentBusy < _nativeDecodeWorkerCount - 1',
    'DecodeExecutionClass.current',
    'DecodeExecutionClass.nonCurrent',
    'Process-lifetime pool',
)
forbid(
    'packages/bridge/lib/src/native_decode_pool.dart',
    '_owners',
    '_closeWhenIdle',
    '_requestShutdown()',
    '_shutdownNow()',
)
require(
    'packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart',
    'NativePipelineMediaRuntimeFactory() {',
    'prewarmNativeDecodeWorkers(),',
    'AndroidTexturePresenter().prewarm(),',
)
require(
    'apps/app/lib/webp_demo.dart',
    'final _defaultNativeMediaRuntimeFactory = NativePipelineMediaRuntimeFactory();',
    'Future<void> prewarmDefaultLocalMediaPipeline()',
)
require(
    'apps/app/lib/main.dart',
    'await prewarmDefaultLocalMediaPipeline();',
    "debugPrint('native media prewarm unavailable: $error');",
    'runApp(const _BootstrapApp());',
)
require(
    'packages/media/lib/src/frame.dart',
    'enum DecodeExecutionClass { current, nonCurrent }',
    'abstract interface class ScheduledFrameCursor',
)
require(
    'packages/sessions/lib/src/decode_session.dart',
    'frames is ScheduledFrameCursor',
    'demand.role == PageRole.current',
    'DecodeExecutionClass.current',
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    '? decode.follow',
    'follow: diff.changed.containsKey(entry.key)',
    'final submit = follow ? upload.follow : upload.submit;',
)
forbid(
    'packages/sessions/lib/src/live_coordinator.dart',
    '? decode.replace',
    'replace: diff.changed.containsKey(entry.key)',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'PageRole.current => 2',
    'PageRole.transition => 1',
)
require(
    'native/media_core/src/webp.rs',
    'MODE_RGBA_PREMULTIPLIED: c_int = 7',
    'decode_rgba_scaled_single_threaded',
    'config.options.use_threads = 0;',
    'premultiply_color(background)',
    'if !snapshot.meta.complete && source_grew',
    'fit_dimensions_never_upscales_sub_alignment_targets',
    'source_over_blends_premultiplied_alpha',
)
forbid(
    'native/media_core/src/webp.rs',
    'config.options.use_threads = 1;',
    'MODE_RGBA: c_int = 1',
)
require(
    'native/media_core/src/android_texture.rs',
    'destination_row.copy_from_slice(source_row);',
    'blit_copies_premultiplied_rgba_and_respects_destination_stride',
)
forbid(
    'native/media_core/src/android_texture.rs',
    'ANativeWindow_setBuffersGeometry',
    'input[0] as u16 * alpha',
)
require(
    'packages/local_media_ui/lib/src/native_webp_player.dart',
    'frames is ScheduledFrameCursor',
    'decodeNextScheduled(DecodeExecutionClass.current)',
)
for path in (
    'packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart',
    'packages/local_media_ui/lib/src/native_webp_player.dart',
):
    forbid(path, '_premultiplyRgbaInPlace')
require(
    'packages/local_media/lib/src/local_image_platform_io.dart',
    'const chunkBytes = 1024 * 1024;',
)
require(
    'packages/local_media_bridge/lib/src/local_media_bridge.dart',
    'localMediaBridgeChunkBytes = 1024 * 1024',
)
require(
    'packages/local_media_bridge/android/src/main/kotlin/dev/zic/localmedia/LocalMediaBridgePlugin.kt',
    'DOCUMENT_CHUNK_BYTES = 1024 * 1024',
    'READ_BUFFER_BYTES = 1024 * 1024',
)
require(
    'packages/transport/lib/src/transport.dart',
    'defaultTransportChunkBytes = 256 * 1024',
)
require(
    'native/libwebp.lock',
    'WEBP_VERSION=1.6.0',
    'WEBP_COMMIT=4fa21912338357f89e4fd51cf2368325b59e9bd9',
    'WEBP_ARCHIVE_SHA256=',
    'WEBP_VP8_DEC_SHA256=',
)
require(
    'tool/fetch_webp.sh',
    'ZIC_WEBP_ARCHIVE',
    'validate_clean_revision',
    'src/upstream/libwebp-',
)
require(
    'tool/prepare_webp.sh',
    'libwebp-vp8-thread-buffer-pool-v1.6.0.patch',
    'verify_libwebp_vp8_tls_patch.py',
    'patch --dry-run --batch --forward --fuzz=0',
    'src/prepared/libwebp-',
)
require(
    'tool/verify_libwebp_vp8_tls_patch.py',
    'competing playback worker/memory pool token',
    'dec->mem_size >= zic_vp8_thread_buffer.size',
)
for path in (
    'tool/build_webp_host.sh',
    'tool/build_webp_android.sh',
    'tool/build_android_native.sh',
):
    require(path, 'tool/prepare_webp.sh')
patch = read('native/patches/libwebp-vp8-thread-buffer-pool-v1.6.0.patch')
for token in (
    'ZIC_VP8_THREAD_LOCAL',
    'zic_vp8_thread_buffer',
    'dec->mem_size >= zic_vp8_thread_buffer.size',
    'This is deliberately a one-entry TLS cache, not an additional worker pool.',
    '@@ -729,7 +753,13 @@',
):
    if token not in patch:
        raise SystemExit(f'FAIL: libwebp patch missing {token!r}')

for path in ROOT.rglob('*'):
    if path.is_file() and path.name == 'webp_worker.rs':
        raise SystemExit(f'FAIL: rejected persistent libwebp worker pool exists: {path}')
for path in ROOT.rglob('*'):
    relative = path.relative_to(ROOT)
    if (
        not path.is_file()
        or path == Path(__file__).resolve()
        or any(part.startswith('.') for part in relative.parts)
    ):
        continue
    if path.suffix not in {'.rs', '.c', '.cc', '.cpp', '.h', '.dart', '.kt', '.py', '.sh'}:
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    if 'WebPSetWorkerInterface(' in text:
        raise SystemExit(f'FAIL: rejected native worker interface in {path}')
require(
    'docs/audits/dev96-local-webp-playback-audit.md',
    '## 问题清单',
    '## 所有权清单',
    '## 被否决方案清单',
)
require('apps/app/pubspec.yaml', 'version: 0.31.0+100')
require('docs/adr/0080-local-webp-resident-single-thread-playback.md', '0.31.0-dev.96')
require('tool/check.sh', 'test_dev96_local_webp_playback.py')
print('dev.96 resident single-thread local WebP playback ownership: OK')
