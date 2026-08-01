#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

screen = (ROOT / 'apps/app/lib/debug_trace_screen.dart').read_text(encoding='utf-8')
exporter = (ROOT / 'apps/app/lib/debug_trace_export.dart').read_text(encoding='utf-8')
activity = (ROOT / 'apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt').read_text(encoding='utf-8')
misc = (ROOT / 'apps/app/lib/misc_page.dart').read_text(encoding='utf-8')

assert "package:file_selector/file_selector.dart" not in screen
assert 'getSaveLocation(' not in screen
assert 'DebugTraceFileExporter?' in screen
assert 'DebugTraceClipboardWriter?' in screen
assert 'const debugTraceClipboardMaxBytes = 64 * 1024;' in screen
assert 'Trace 复制失败：$error' in screen
assert 'Trace 导出失败：$error' in screen

assert "defaultTargetPlatform == TargetPlatform.android" in exporter
assert "dev.zic.zic/debug_trace_export" in exporter
assert "'saveJsonl'" in exporter
assert 'getSaveLocation(suggestedName: suggestedName)' in exporter

for token in (
    'Intent.ACTION_CREATE_DOCUMENT',
    'startActivityForResult(intent, TRACE_EXPORT_REQUEST)',
    'onActivityResult(requestCode: Int, resultCode: Int, data: Intent?)',
    'pendingTraceResult',
    'pendingTraceBytes',
    'contentResolver.openOutputStream(uri, "wt")',
    'trace-export-busy',
    'trace-export-write-failed',
):
    assert token in activity
assert 'exportFile: exportDebugTraceDocument' in misc
print('Android Trace export and independent clipboard contract: OK')
