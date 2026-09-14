#!/usr/bin/env python3
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.223 missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.223 forbidden {label}: {token}')

runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
exports = read('packages/downloads/lib/downloads.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
live = read('packages/sessions/lib/src/live_coordinator.dart')
pipeline = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
chapter = read('packages/downloads/lib/src/chapter_downloads.dart')
persistent_chapter_service = read(
    'packages/downloads/lib/src/persistent_chapter_download_service.dart'
)
persistent_store = read('packages/downloads/lib/src/persistent_download_artifact_store.dart')
whole = read('packages/downloads/lib/src/whole_comic_downloads.dart')
main = read('apps/app/lib/main.dart') + read('apps/app/lib/app_runtime.dart')
local_media_composition = read('apps/app/lib/local_media_composition.dart')
home = read('apps/app/lib/demo_home.dart')
reader_route = read('apps/app/lib/demo_home_reader_route.dart')
owner_test = read('packages/sessions/test/download_transfer_owner_test.dart')
chapter_test = read('packages/downloads/test/chapter_downloads_test.dart')
transport = read('packages/transport/lib/src/transport.dart')
job = read('packages/sessions/lib/src/download_job.dart')
session = read('packages/sessions/lib/src/download_session.dart')
handoff = read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
cache_transport = read('packages/downloads/lib/src/artifact_cache_transport.dart')
cache_manager = read('packages/downloads/lib/src/artifact_cache_manager.dart')

require(exports, "export 'src/composition_download_transfer_runtime.dart';", 'public composition runtime export')
for token in (
    'final class CompositionDownloadTransferRuntime',
    'late final DownloadRegistry registry;',
    'late final DownloadTransferOwner owner;',
    'DownloadTransferConsumer attachConsumer(',
    'Future<void> persistPromoted(DownloadId id)',
    'final class CompositionDownloadTransferRuntimePool',
):
    require(runtime, token, 'downloads-owned composition runtime')

forbid(pipeline, '_PipelineDownloadTransferRuntime', 'Reader-private physical runtime class')
for token in (
    'final CompositionDownloadTransferRuntime? transferRuntime;',
    'PipelineReaderSessionFactory withTransferRuntime(',
    'required CompositionDownloadTransferRuntime transferRuntime,',
    '_downloads = _transferRuntime.registry;',
    '_downloadTransfer = _transferRuntime.attachConsumer(',
    'identityHashCode(transferRuntime),',
):
    require(pipeline, token, 'Reader consumer attachment to composition runtime')

forbid(owner, "import 'package:pipeline/pipeline.dart';", 'physical owner pipeline-policy dependency')
for token in (
    'final class TransferDemand',
    'final int priority;',
    'final String reason;',
    'final String? expectedChecksum;',
    'final TransferCompletionIntent completionIntent;',
    'bool _requiresCompletion(DownloadId id)',
    'void _validateDemandChecksums(',
    'Map<DownloadId, TransferDemand> desired',
):
    require(owner, token, 'policy-neutral transfer claim')
for token in (
    'TransferDemand(',
    'priority: entry.value.priority,',
    'reason: entry.value.reason,',
    '_downloadTransfer.replaceDemands(',
):
    require(live, token, 'Reader demand projection at LiveCoordinator boundary')

require(persistent_store, 'final class PersistentDownloadArtifactStore', 'durable store split')
require(chapter, 'final class PersistentDownloadComposition', 'application composition owner')
require(chapter, 'abstract interface class ChapterDownloadTransferRuntimeProvider', 'composition provider seam')
require(persistent_chapter_service, 'final CompositionDownloadTransferRuntime transferRuntime;', 'chapter command shared runtime')
require(persistent_chapter_service, "scopeId: 'chapter-command:$identity'", 'chapter command scoped consumer')
require(persistent_chapter_service, "reason: 'chapter-download-command'", 'chapter transfer claim reason')
require(persistent_chapter_service, 'completionIntent: TransferCompletionIntent.required,', 'chapter durable completion intent')
require(persistent_chapter_service, 'await transferRuntime.persistPromoted(id);', 'durable completion barrier')
require(persistent_chapter_service, 'await consumer.dispose();', 'chapter claim lifecycle')

service_start = persistent_chapter_service.index('final class PersistentChapterDownloadService')
service = persistent_chapter_service[service_start:]
for token in ('DownloadJob(', 'DownloadRegistry(', 'NetLane('):
    forbid(service, token, 'chapter command physical transfer owner')

managed_start = chapter.index('abstract interface class ManagedChapterDownloadService')
managed_end = chapter.index('/// Resolves bytes owned', managed_start)
managed = chapter[managed_start:managed_end]
for token in ('ArtifactCacheBackend', 'ArtifactCacheMaintenance'):
    forbid(managed, token, 'command/cache ownership conflation')

for token in ('DownloadJob(', 'DownloadRegistry(', 'NetLane(', 'Transport '):
    forbid(whole, token, 'whole-comic physical transfer owner')
require(whole, 'final ChapterDownloadService _downloads;', 'whole-comic chapter-command aggregation')

for token in (
    'PersistentDownloadComposition.open(',
    'transferNet: defaultDownloadResourceCoordinator.networkLane,',
    'downloadComposition.artifactStore',
    'downloadComposition.chapterDownloads',
    'shutdownDefaultLocalMediaPipeline()',
):
    require(main, token, 'application composition shared owner wiring')
for token in (
    'final defaultDownloadResourceCoordinator = DownloadResourceCoordinator();',
    'pageDownloadLane: defaultDownloadResourceCoordinator.networkLane,',
    'defaultLocalMediaPipelineFactory.disposeRetainedSessions()',
):
    require(local_media_composition, token, 'application network resource composition root')
require(pipeline, 'required this.pageDownloadLane,', 'Reader factory explicit NetLane ownership')
forbid(pipeline, 'pageDownloadLane ??', 'Reader factory implicit NetLane fallback')
require(live, 'required NetLane net,', 'LiveCoordinator explicit NetLane ownership')
forbid(live, 'net ?? NetLane(', 'LiveCoordinator implicit NetLane fallback')
composition_start = chapter.index('final class PersistentDownloadComposition')
composition_end = chapter.index('typedef _PersistentDownloadAuthorities', composition_start)
composition = chapter[composition_start:composition_end]
require(composition, 'required NetLane transferNet,', 'persistent composition explicit NetLane ownership')
for token in (
    'ChapterDownloadTransferRuntimeProvider',
    '.artifactCacheManager',
    '.artifactStore',
):
    require(home, token, 'home durable capability wiring')
for token in (
    '.withTransferRuntime(',
    '.transferRuntime',
    '.artifactStore',
):
    require(reader_route, token, 'Reader shared transfer wiring')

for token in (
    'enum ByteResponseBodyAuthority',
    'artifactCache',
    'final ByteResponseBodyAuthority bodyAuthority;',
):
    require(transport, token, 'immutable body authority split')
for token in (
    'bool get residentBodyBacked',
    'bool get residentBodyBacked',
    'ByteResponseBodyAuthority? get residentBodyAuthority',
    'void beginResidentImmutableIngress(',
    'void appendResidentImmutableIngress(',
    'DownloadSnapshot sealResidentImmutableIngress({',
):
    require(session, token, 'resident body/cache ownership terminology split')

require(job, 'bodyAuthority: response.bodyAuthority,', 'resident provenance assignment')
for token in (
    'bodyAuthority: durable',
    'ByteResponseBodyAuthority.artifactCache',
):
    require(cache_transport, token, 'artifact-cache body authority assignment')
require(cache_manager, 'Future<bool> containsBackendExact(', 'exact durable identity probe')

for token in (
    'Future<void> persist(',
    'requireExactDurableBody: true',
    'cache.containsBackendExact(',
    "action: 'defer-resident-source'",
    "'stored-resident-source'",
    'residentReplaySource',
    'requiredExactTargets',
):
    require(handoff, token, 'resident durable materialization barrier')
for token in (
    'Future<Stream<List<int>>> openResidentReplay(',
    'resident replay requires an attached transfer consumer',
):
    require(owner, token, 'composition resident replay authority')

for token in (
    'transfer checksum constraints aggregate across consumers atomically',
    'required completion claim can finish a costly full-body catchup',
    'expect(conflicting.demands, isEmpty);',
    'expect(owner.claimCount(id), 2);',
):
    require(owner_test, token, 'checksum multi-consumer behavior regression')
for token in (
    'chapter command joins an existing composition physical transfer',
    'chapter cancellation removes only its composition transfer claim',
    'expect(readerTransport.opens, 1);',
    'service.transferRuntime.owner.claimCount(id)',
    'expect(await service.readPage(entry, 0), bytes);',
    "expect(physical.residentSource, 'reopenable-immutable-source');",
    'expect(await first.artifactStore.openArtifactStream(id), isNotNull);',
):
    require(chapter_test, token, 'chapter/Reader shared-transfer behavior regression')

for rel in (
    'docs/adr/0204-composition-transfer-runtime-and-chapter-command-claims.md',
    'docs/audits/dev223-chapter-transfer-claim-migration-root-cause-audit.md',
    'docs/audits/dev223-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.223 missing governance: {rel}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub is None or int(pub.group(1)) < 223:
    raise SystemExit('dev.223 app version mismatch')
if android is None or int(android.group(1)) < 223:
    raise SystemExit('dev.223 Android version mismatch')

print('dev.223 chapter command / composition transfer claim migration: OK')
