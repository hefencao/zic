#!/usr/bin/env python3
"""Guard dev.289 Pipeline frame/notifier boundary consolidation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def text(path):
    return (ROOT / path).read_text(encoding='utf-8')


def req(ok, msg):
    if not ok:
        raise SystemExit(f'FAIL: {msg}')


def require(path, *markers):
    body = text(path)
    missing = [marker for marker in markers if marker not in body]
    req(not missing, f'{path} missing dev.289 contract: {missing}')


pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 289, 'dev.289 app version missing')
props = text('apps/app/android/zic-version.properties')
m = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(m is not None and int(m.group(1)) >= 289, 'dev.289 Android version missing')

require(
    'packages/pipeline_runtime/lib/src/pipeline_frame_scheduler.dart',
    'abstract interface class PipelineFrameScheduler',
    'bool get inPersistentCallbacks;',
    'bool get isIdle;',
    'void afterFrame(void Function() callback);',
    'void requestFrame();',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart',
    'PipelineFrameScheduler get frameScheduler;',
)

output = text('packages/pipeline_runtime/lib/src/pipeline_page_output.dart')
for marker in (
    'required PipelineFrameScheduler frameScheduler,',
    'final PipelineFrameScheduler _frameScheduler;',
    '_frameScheduler.afterFrame(() {',
    '_frameScheduler.requestFrame();',
):
    req(marker in output, f'output scheduler boundary missing: {marker}')
for forbidden in ('WidgetsBinding', 'SchedulerBinding', 'package:flutter/'):
    req(forbidden not in output, f'output stream still leaks Flutter frame owner: {forbidden}')

progress = text('packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart')
for marker in (
    'final class PipelineTransferProgressFeed',
    'PipelineTransferProgress get value => _value;',
    'void addListener(',
    'required PipelineFrameScheduler frameScheduler,',
    'final PipelineTransferProgressFeed feed;',
    '_frameScheduler.afterFrame(() {',
):
    req(marker in progress, f'transfer progress boundary missing: {marker}')
for forbidden in (
    'package:flutter/',
    'WidgetsBinding',
    'SchedulerBinding',
    'ValueNotifier',
    'ValueListenable',
):
    req(forbidden not in progress, f'transfer progress leaks Flutter owner: {forbidden}')

session = text('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for marker in (
    'frameScheduler: _media.frameScheduler,',
    'transferProgress = PipelineTransferProgressPublisher(',
):
    req(marker in session, f'session scheduler composition missing: {marker}')

native = text('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')
for marker in (
    'final class _FlutterPipelineFrameScheduler implements PipelineFrameScheduler',
    'SchedulerBinding.instance.schedulerPhase',
    'PipelineFrameScheduler get frameScheduler =>',
):
    req(marker in native, f'native Flutter scheduler adapter missing: {marker}')

reader = text('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
req('ReaderTransferProgressFeedIndicator(' in reader, 'Reader feed projection missing')
req('ValueListenableBuilder<PipelineTransferProgress>' not in reader,
    'Reader still consumes transfer progress through Flutter ValueListenable')
req(not (ROOT / 'packages/reader_runtime/lib/src/reader_download_progress.dart').exists(),
    'dead Reader progress publisher facade still exists')
req("export 'src/reader_download_progress.dart';" not in text('packages/reader_runtime/lib/reader_runtime.dart'),
    'Reader barrel still exports dead progress publisher facade')
indicator = text('packages/reader_runtime/lib/src/reader_transfer_progress_indicator.dart')
for marker in (
    'final PipelineTransferProgressFeed feed;',
    'feed.addListener(_onProgress, fireImmediately: false);',
    'widget.feed.removeListener(_onProgress);',
):
    req(marker in indicator, f'Reader transfer feed adapter missing: {marker}')

# pipeline_runtime remains a Flutter package because it intentionally exports
# the opaque Widget surface ABI, the Reader host and root asset adapter. All
# other runtime/source-projection files must stay framework-binding free.
flutter_import_files = set()
for path in (ROOT / 'packages/pipeline_runtime/lib/src').glob('*.dart'):
    body = path.read_text(encoding='utf-8')
    if 'package:flutter/' in body:
        flutter_import_files.add(path.name)
req(
    flutter_import_files == {
        'asset_bundle_transport.dart',
        'pipeline_media_runtime.dart',
        'pipeline_reader_host.dart',
    },
    f'unexpected pipeline_runtime Flutter seams: {sorted(flutter_import_files)}',
)

require(
    'packages/pipeline_runtime/test/pipeline_transfer_progress_test.dart',
    'publisher.feed.value',
    'frameScheduler: const _TestFrameScheduler()',
)
for path in (
    'docs/archive/adr/0268-pipeline-frame-scheduler-and-projection-boundary.md',
    'docs/archive/audits/dev289-pipeline-flutter-binding-closure-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.289 governance file: {path}')
require('docs/ARCHITECTURE.md', 'PipelineFrameScheduler', 'PipelineTransferProgressFeed')
require('docs/SPEC.md', 'PipelineFrameScheduler', 'PipelineTransferProgressFeed')
require('CHANGELOG.md', '0.31.0-dev.289', 'Pipeline frame scheduler boundary')
req('test_dev289_pipeline_frame_scheduler_boundary.py' in text('tool/check.sh'),
    'dev.289 gate not wired into tool/check.sh')
print('PASS: dev.289 Pipeline frame/notifier boundary consolidation')
