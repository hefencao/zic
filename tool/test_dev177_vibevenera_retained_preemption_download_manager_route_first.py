#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')

coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
for token in (
    "reason: 'retained-background'",
    'final receiving = session?.state == DownloadState.receiving;',
    'net.cancel(taskKey);',
    'net.cancelQueued(taskKey);',
    '_migrateDownloadPriority(',
):
    require(coordinator, token, 'VibeVenera logical-detach retention')
forbid(coordinator, 'final wasActive = net.isActive(taskKey);', 'exact detach cancellation')

lane = read('packages/sessions/lib/src/net_lane.dart')
for token in (
    '_highestBlockedHighPriorityPending()',
    '_preemptLowestRunningFor(blockedHighPriority)',
    'maxActive + reservedHighPrioritySlots',
):
    require(lane, token, 'bounded saturated current preemption')

lane_test = read('packages/sessions/test/net_lane_test.dart')
require(lane_test, 'blocked current keeps preempting low work while the handoff slot unwinds', '5+1 handoff regression')

coordinator_test = read('packages/sessions/test/live_coordinator_test.dart')
for token in (
    'active nonresumable transfer survives window detach and is not reopened',
    "expect(coordinator.net.priorityOf('reader:${id.key}'), 0);",
    "expect(coordinator.net.priorityOf('reader:${id.key}'), 1000);",
    'expect(transport.opens, 1);',
):
    require(coordinator_test, token, 'quick detach/reattach no-redownload regression')

adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
for token in (
    'preemptControlledActiveForCurrent:',
    'currentPriorityThreshold = 1000',
    'incoming.priority - active.control.priority < preemptionThreshold',
    'active.preemptRequested = true;',
    "runtimeError.code == 'runtime-request-cancelled'",
    'ErrorCode.cancelled',
):
    require(adapter, token, 'Venera nested current-pressure preemption')

adapter_test = read('packages/plugin_host/test/runtime_source_adapter_test.dart')
for token in (
    'controlled Venera resource work cancels active prefetch and admits current before queued prefetch',
    'The current request itself preempts the lower-ranked active Venera',
    "code: 'runtime-request-cancelled'",
    'expect(connection.cancelledRequestIds, hasLength(1));',
):
    require(adapter_test, token, 'Venera pressure regression')

manager = read('apps/app/lib/download_manager.dart')
for token in (
    'this.initialSnapshots = const <ChapterDownloadSnapshot>[]',
    'this.initialWholeComicSnapshot,',
    'bool _loading = false;',
    'WidgetsBinding.instance.addPostFrameCallback',
    'unawaited(_refreshAfterFirstFrame());',
    'widget.downloads.inspectMany(_entries.values)',
):
    require(manager, token, 'route-first download manager')
for token in ('scheduleMicrotask(_reload)', '_entries.values.map(widget.downloads.inspect)'):
    forbid(manager, token, 'pre-frame per-entry inspection')

home = read('apps/app/lib/demo_home.dart')
for token in (
    'initialSnapshots: List<ChapterDownloadSnapshot>.unmodifiable(',
    '_downloadSnapshots.values,',
    'initialWholeComicSnapshot: _wholeComicQueueSnapshot,',
):
    require(home, token, 'Home download projection handoff')

manager_test = read('apps/app/test/chapter_downloads_test.dart')
for token in (
    'download manager paints before durable bulk refresh completes',
    'expect(find.byKey(downloadManagerScreenKey), findsOneWidget);',
    'expect(releaseRefresh.isCompleted, isFalse);',
):
    require(manager_test, token, 'route-first widget regression')

check = read('tool/check.sh')
require(check, 'test_dev177_vibevenera_retained_preemption_download_manager_route_first.py', 'release gate wiring')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 177:
    raise SystemExit('App build must be at least 177')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.177 VibeVenera retained-preemption / download-manager route-first contract: OK')
