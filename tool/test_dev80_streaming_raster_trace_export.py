#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


raster = read('packages/pipeline/lib/src/aligned_raster_size.dart')
target = read('packages/pipeline/lib/src/decode_target.dart')
webp = read('native/media_core/src/webp.rs')
local_player = read('packages/local_media_ui/lib/src/local_image_player.dart')
ingress = read('packages/media/lib/src/ingress.dart')
download = read('packages/sessions/lib/src/download_session.dart')
ingress_projection = read(
    'packages/sessions/lib/src/download_ingress_projection.dart'
)
coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
progress = read('packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart')
reader_progress = read(
    'packages/reader_runtime/lib/src/reader_transfer_progress_indicator.dart'
)
trace_screen = read('apps/app/lib/debug_trace_screen.dart')
trace_export = read('apps/app/lib/debug_trace_export.dart')
android = read('apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt')
misc = read('apps/app/lib/misc_page.dart')

for token in (
    'final class AlignedRasterSize',
    'alignment = 8',
    'aspectError',
    'minimumArea',
):
    assert token in raster
assert 'AlignedRasterSize.fit(' in target
for token in ('const ALIGNMENT: usize = 8;', 'align_ratio_closest(', 'minimum_area'):
    assert token in webp

for token in (
    'final class MediaAspectViewport',
    'final class MediaRasterImage',
    'builder(BoxFit.fill)',
    'return SizedBox.expand(child: builder(fit));',
    '_streamingPrefixRequestedLength',
    'authoritative: false',
    'AlignedRasterSize.fit(',
):
    assert token in local_player
assert 'surface.width, surface.height);' not in local_player

for token in ('final int revision;', 'revision: _revision', '_revision++;'):
    assert token in ingress
assert 'before.revision != after.revision' in ingress_projection
for token in (
    'final Map<DownloadId, int> _sourceRevisions',
    '_sourceRevisions[id] = snapshot.revision;',
    '_decodeSourceRevisions[id] = sourceRevision;',
    '_sourceRevisions.remove(id);',
):
    assert token in coordinator

for token in (
    'enum PipelineTransferPhase',
    'PipelineTransferPhase.receiving',
    'final int partialBytes;',
    'final int transportBytes;',
):
    assert token in progress
assert "PipelineTransferPhase.receiving => '正在接收页面数据'" in reader_progress
assert "PipelineTransferPhase.connecting => '正在连接页面资源'" in reader_progress

assert "package:file_selector/file_selector.dart" not in trace_screen
for token in (
    'DebugTraceClipboardWriter',
    'debugTraceClipboardMaxBytes',
    '_boundedClipboardPayload',
    'Trace 复制失败：$error',
    'DebugTraceEventsExporter',
    '_exporting',
):
    assert token in trace_screen
for token in ('exportDebugTraceEvents', 'dev.zic.zic/debug_trace_export'):
    assert token in trace_export
for token in (
    'Intent.ACTION_CREATE_DOCUMENT',
    'saveJsonl',
    'saveJsonlToDownloadsDirectory',
    'contentResolver.openOutputStream',
):
    assert token in android
assert 'exportDirectory: preferences.debugTraceExportDirectory' in misc
assert 'onExportDirectoryChanged:' in misc

for rejected in (
    'getSaveLocation(suggestedName: suggestedName)',
    'exportDebugTraceFile',
):
    assert rejected not in trace_screen

assert (ROOT / 'docs/audits/dev80-streaming-raster-and-trace-export-audit.md').is_file()
assert (ROOT / 'docs/adr/0064-unified-raster-and-platform-trace-export.md').is_file()
print('dev.80 streaming, raster and trace export ownership: OK')
