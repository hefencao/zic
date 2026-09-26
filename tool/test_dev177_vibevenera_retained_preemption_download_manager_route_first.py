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
transfer_owner_path = ROOT / 'packages/sessions/lib/src/download_transfer_owner.dart'
physical_owner = (transfer_owner_path.read_text(encoding='utf-8')
                  if transfer_owner_path.exists() else coordinator)
build_match = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
build = int(build_match.group(1)) if build_match is not None else 0
retention_tokens = [
    ("reason: 'inactive-physical-retention'"
     if build >= 267 else
     "reason: 'retained-background'"),
    'net.cancelQueued(taskKey);',
    '_migrateDownloadPriority(',
]
if build < 243:
    retention_tokens.extend((
        'final receiving = session?.state == DownloadState.receiving;',
        'net.cancel(taskKey);',
    ))
elif build < 267:
    retention_tokens.extend((
        'taskKey != null && taskIsActive',
        'Logical demand detachment never decides whether already-admitted work',
    ))
else:
    retention_tokens.extend((
        'taskKey != null && taskIsActive',
        'Working-set membership and physical transport lifetime are separate',
        'net.updateDemanded(taskKey, false);',
    ))
for token in retention_tokens:
    require(physical_owner, token, 'VibeVenera logical-detach retention')
if build >= 243:
    forbid(physical_owner, 'final receiving = session?.state == DownloadState.receiving;', 'state-taxonomy detach retention')
forbid(physical_owner, 'final wasActive = net.isActive(taskKey);', 'exact detach cancellation')

lane = read('packages/sessions/lib/src/net_lane.dart')
for token in (
    '_highestBlockedHighPriorityPending()',
    '_preemptLowestRunningFor(blockedHighPriority)',
    'maxActive + reservedHighPrioritySlots',
):
    require(lane, token, 'bounded saturated current preemption')

lane_test = read('packages/sessions/test/net_lane_test.dart')
require(
    lane_test,
    ('blocked current preempts only after reserved headroom is occupied'
     if build >= 245 else
     'blocked current keeps preempting low work while the handoff slot unwinds'),
    '5+1 handoff regression',
)

coordinator_test = read('packages/sessions/test/live_coordinator_test.dart')
for token in (
    'active nonresumable transfer survives window detach and is not reopened',
    'coordinator.downloadTaskKeyFor(id)!',
    'expect(transport.opens, 1);',
):
    require(coordinator_test, token, 'quick detach/reattach no-redownload regression')
for priority in (0, 1000):
    if re.search(
        rf'coordinator\.net\.priorityOf\(coordinator\.downloadTaskKeyFor\(id\)!\),\s*{priority},',
        coordinator_test,
    ) is None:
        raise SystemExit(
            f'missing quick detach/reattach priority regression: {priority}'
        )

adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
for token in (
    'controlledPreemptionPriorityFloor:',
    '? 780',
    'incoming.priority < controlledPreemptionPriorityFloor',
    'incoming.priority - activeControl.priority < preemptionThreshold',
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
    'this.resolveServices,',
    'this.serviceChanges,',
    'this.projectionChanges,',
    'this.readProjection,',
    'this.refreshProjection,',
    'int _serviceGeneration = 0;',
    'int _resolvedServiceGeneration = -1;',
    'bool _loading = false;',
    'WidgetsBinding.instance.addPostFrameCallback',
    'unawaited(_refreshAfterFirstFrame());',
    'widget.serviceChanges?.addListener(_handleServiceChanged);',
    'widget.projectionChanges?.addListener(_handleProjectionChanged);',
    '_serviceGeneration++;',
    'while (mounted && widget.resolveServices != null &&',
    '_resolvedServiceGeneration != _serviceGeneration)',
    'if (!mounted || generation != _serviceGeneration)',
    'unawaited(_refreshServicesAfterChange());',
    'if (widget.readProjection == null)',
    'await _resolveServices();',
    '_downloads.inspectMany(_entries.values)',
    '_entryIdentityByChapter',
    'ListView.builder(',
    'this.commandActions,',
    'final actions = widget.commandActions;',
    'await actions.downloadChapter(entry)',
    'await actions.retryChapter(entry)',
    'await actions.deleteChapterFiles(entry)',
    '_DownloadManagerQueueCommand',
):
    require(manager, token, 'route-first download manager')
task_action_start = manager.index('Future<void> _performTaskAction(')
task_action_end = manager.index(
    'Future<void> _convertCacheToDownload(',
    task_action_start,
)
task_action = manager[task_action_start:task_action_end]
hydrate_wait = task_action.index('final hydrated = await widget.hydrateEntry!')
actions_branch = task_action.index('if (actions != null) {')
fallback_branch = task_action.index('} else {', actions_branch)
fallback_resolve = task_action.index(
    'await _resolveServices();',
    fallback_branch,
)
downloads_capture = task_action.index('final downloads = _downloads;', fallback_branch)
if not hydrate_wait < fallback_resolve < downloads_capture:
    raise SystemExit(
        'standalone chapter fallback must re-resolve after hydrate before service capture'
    )
if 'await _resolveServices();' in task_action[actions_branch:fallback_branch]:
    raise SystemExit(
        'Home chapter commandActions branch must not add a post-hydrate concrete resolve'
    )

policy_start = manager.index('Future<void> _editQueuePolicy() async {')
policy_end = manager.index(
    'Future<void> _queueAction(',
    policy_start,
)
policy_flow = manager[policy_start:policy_end]
actions_branch = policy_flow.index('if (actions != null) {')
fallback_branch = policy_flow.index('} else {', actions_branch)
fallback_update = policy_flow.index(
    'await _wholeComicDownloads.updatePolicy(selected);',
    fallback_branch,
)
fallback_resolve = policy_flow.index(
    'await _resolveServices();',
    fallback_branch,
)
if fallback_resolve > fallback_update:
    raise SystemExit(
        'standalone policy fallback must re-resolve current services after dialog'
    )
if 'await _resolveServices();' in policy_flow[actions_branch:fallback_branch]:
    raise SystemExit(
        'Home commandActions policy path must not resolve concrete route services'
    )

for token in (
    'scheduleMicrotask(_reload)',
    '_entries.values.map(widget.downloads.inspect)',
    '_entries.values.map(_downloads.inspect)',
    '_entries.keys.firstWhere(',
    '_act(snapshot, _downloads.',
    '_performTaskAction(snapshot, _downloads.',
):
    forbid(manager, token, 'pre-frame per-entry inspection')

home = '\n'.join((
    read('apps/app/lib/home_shell.dart'),
    read('apps/app/lib/home_shell_source_compat.dart'),
))
for token in (
    'final initialProjection = readProjection();',
    'initialSnapshots: initialProjection.snapshots,',
    'initialWholeComicSnapshot: initialProjection.wholeComicSnapshot,',
    'serviceChanges: _serviceHandoff,',
    'projectionChanges: _librarySession.downloadProjectionChanges,',
    'readProjection: readProjection,',
    'refreshProjection: () =>',
    'resolveServices: () async {',
    'await _serviceHandoff?.ensureCoreServices?.call();',
    'await _serviceAdoption.adoptCurrent();',
):
    require(home, token, 'Home download projection handoff')

home_manager = read('apps/app/lib/home_shell_source_compat.dart')
manager_open = home_manager[home_manager.index('Future<void> _openDownloadManager()'):]
for token in (
    'loadAllEntries:',
    'await _refreshDownloadSnapshots(_libraryEntries);',
):
    forbid(manager_open, token, 'download-manager route storage ownership')

home_session = read('apps/app/lib/home_library_session.dart')
for token in (
    'List<ImportedLibraryEntry> get downloadManagerEntries',
    'ChapterDownloadManagementProjectionReader',
    'inspectDownloadManagement(',
    '_startupDownloadProjectionEntries(',
    '_refreshKnownDownloadSnapshots(',
    'service.inspectMany(requested)',
    'download-snapshot-persist-skip reason=unchanged',
    "unawaited(_refreshDownloadSnapshotsAfterFrame(_entries));",
):
    require(home_session, token, 'Home-owned download management projection')

downloads = read('packages/downloads/lib/src/persistent_chapter_download_service.dart')
persistent_start = downloads.index('final class PersistentChapterDownloadService')
management_start = downloads.index(
    'Future<ChapterDownloadManagementProjection> inspectDownloadManagement(',
    persistent_start,
)
management_end = downloads.index(
    'List<ImportedLibraryEntry> _discoverOrphanedEntriesFromRecords(',
    management_start,
)
management = downloads[management_start:management_end]
if management.count('artifactStore.indexedRecords()') != 1:
    raise SystemExit(
        'persistent download-management projection must read the artifact index exactly once'
    )

manager_test = read('apps/app/test/chapter_downloads_test.dart')
for token in (
    'download manager paints before durable bulk refresh completes',
    'expect(find.byKey(downloadManagerScreenKey), findsOneWidget);',
    'expect(releaseRefresh.isCompleted, isFalse);',
    'expect(taskList.childrenDelegate, isA<SliverChildBuilderDelegate>());',
    'download manager keeps persisted Home projection visible during handoff',
    'expect(releaseServices.isCompleted, isFalse);',
    'download manager chapter fallback re-resolves after hydrate generation change',
    'download manager re-resolves services after a later generation change',
    'download manager policy fallback re-resolves after an open dialog',
    'download manager catches a generation change during service resolution',
    'download manager stops resolving when disposed during service handoff',
    'download manager cache maintenance follows the latest service generation',
    'download manager adopts durable projection and revalidates through owner',
    'resolveServices: () async {',
    'expect(task, findsOneWidget);',
    'expect(durableView.inspectManyStarted, isFalse);',
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
