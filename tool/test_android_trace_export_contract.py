#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

screen = (ROOT / 'apps/app/lib/debug_trace_screen.dart').read_text(encoding='utf-8')
exporter = (ROOT / 'apps/app/lib/debug_trace_export.dart').read_text(encoding='utf-8')
destination = (ROOT / 'apps/app/lib/debug_trace_export_destination.dart').read_text(encoding='utf-8')
activity = (ROOT / 'apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt').read_text(encoding='utf-8')
misc = (ROOT / 'apps/app/lib/misc_page.dart').read_text(encoding='utf-8')
home = (ROOT / 'apps/app/lib/demo_home_views.dart').read_text(encoding='utf-8')

assert "package:file_selector/file_selector.dart" not in screen
assert 'getSaveLocation(' not in screen
assert 'DebugTraceEventsExporter?' in screen
assert 'DebugTraceClipboardWriter?' in screen
assert 'const debugTraceClipboardMaxBytes = 64 * 1024;' in screen
assert 'Trace 复制失败：$error' in screen
assert 'Trace 导出失败：$error' in screen

assert "defaultTargetPlatform == TargetPlatform.android" in exporter
assert "dev.zic.zic/debug_trace_export" in exporter
assert "'saveJsonl'" in exporter
assert "'saveJsonlToDownloadsDirectory'" in exporter
assert 'exportDebugTraceEvents(' in exporter
assert 'getSaveLocation(suggestedName: suggestedName)' in exporter
assert "defaultDebugTraceExportDirectory = 'Debug'" in destination
assert "'Download/${normalizeDebugTraceExportDirectory(relativeDirectory)}'" in destination

for token in (
    'Intent.ACTION_CREATE_DOCUMENT',
    'startActivityForResult(intent, TRACE_EXPORT_REQUEST)',
    'onActivityResult(requestCode: Int, resultCode: Int, data: Intent?)',
    'pendingTraceResult',
    'pendingTraceBytes',
    'contentResolver.openOutputStream(uri, "wt")',
    'trace-export-busy',
    'trace-export-write-failed',
    'trace-export-host-paused',
    'trace-export-missing-result-cleared',
    'MediaStore.Downloads.RELATIVE_PATH',
    'saveTraceToDownloadsDirectory(',
    'relativeDirectory',
):
    assert token in activity
compact_misc = ''.join(misc.split())
assert 'exportDirectory:preferences.debugTraceExportDirectory' in compact_misc
assert 'onExportDirectoryChanged:' in misc
assert 'exportDebugTraceEvents(' in home
assert 'widget.preferences.debugTraceExportDirectory' in home
print('Android Trace export and independent clipboard contract: OK')
