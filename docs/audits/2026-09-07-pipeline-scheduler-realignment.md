# Pipeline scheduler ownership realignment audit

## Scope

User-requested re-audit around `e97b8fb3e995ffb47b3364b460ffe959938ed07d`, with the directly relevant earlier compatibility layer included when it materially changes the conclusion.

## Finding

`e97b8fb3` is not a clean pre-regression baseline. The earlier `99243721` introduced two stop-gap eligibility schedulers to suppress cached-page restore pressure: foreground local prepare blocked all background prepare, and Reader ingress replay inferred page classes from `1000/780` priority thresholds plus memory pressure. Later work introduced composition-owned `ArtifactCacheReadScheduler` and the established Pipeline staged policy, but those stop-gap gates were not retired. The result was duplicated scheduling: Pipeline still emitted the intended 7/3 download window, 2/1 media window and staged `c/n/m/p` refill decisions, while lower source/local-restore layers could independently deny the work.

## Phase A disposition

- Keep `NetLane`, `ArtifactCacheReadScheduler`, `StorageWriteScheduler`, staged decode refill, FrameBudgeter, retry ownership, presentation recovery and Reader re-entry media purge.
- `DownloadTransferOwner` local prepare is now only a bounded operation queue (max two) ordered by current effective priority. It is not a page eligibility policy. Persistent body reads remain chunk-scheduled by the shared artifact read scheduler.
- A broad DownloadDemand no longer eagerly creates Reader ingress. Reader-local source is held by active DecodeDemand / UploadDemand or an UploadRegistry-approved retained static output. Once none remain, dependent upload/decode/native-cursor state and ingress/source ownership are released.
- `DownloadIngressProjectionRegistry` remains a bounded priority replay queue but no longer infers PageRole from `1000/780` thresholds or owns a memory-pressure gate. Memory pressure remains a Pipeline/media-budget fact.

## Explicitly deferred Phase B

`PersistentDownloadArtifactStore.openPartialDownload()` still exposes an exact READY durable final through the historical partial compatibility path, and `exactDurableFinal` / `skip-restored-exact-durable` still compensate that path. Removing it directly caused a generic composition consumer to reopen the provider. The correct replacement requires separating durable immutable authority/completeness from Reader-ingress hydrated length; reusing current `residentBodyBacked` counters without that split would falsely claim bytes have already entered Reader ingress. Therefore Phase B must be a separate authority-model change with its own tests, not part of scheduler cleanup.

## Validation

Phase A closeout validation: sessions 293/293, pipeline_runtime 23/23, downloads 272/272, and App 193 passed / 3 skipped. The 279 executable Python contracts remain exactly at the canonical baseline split of 261 pass / 18 historical failures, with zero new failures. Repository, documentation, Dart-structure and quarantine gates are green. Affected analyze reports zero errors and zero warnings; repository-wide info lints remain historical baseline. Existing static-output demand-gap, physical-generation rebind, network flow-control, partial adoption, artifact replica/migration and presentation recovery tests remain green.

## Device trace confirmation

Updated `.log/zic-debug-trace.jsonl` after Phase A contains 1,891 events. `pipeline-reader-2` repeatedly holds 11 DownloadDemands and four DecodeDemands while moving through pages rather than creating media work only when a page becomes current. Across the trace there are 20 DecodeDemand, 20 UploadDemand and 18 sourceReady events for 11 pageCurrent transitions. Concrete pre-current first-frame evidence includes page 33 at 16.4 ms lead, page 36 at 684.4 ms lead, reverse page 31 at 157.7 ms lead and reverse page 29 at 67.1 ms lead. This closes the specific regression claim that lower eligibility gates had collapsed staged preloading to current-only behavior.

The same trace also separates the remaining latency from Phase A. Exact READY durable pages still produce 11 `session-partial-handoff/restored` events followed by 11 `session-artifact-handoff/skip-restored-exact-durable` events. The restored-to-skip span is 322.3–685.0 ms (median 388.3 ms), while full durable handoff itself reaches 1.5–2.6 s for 15–18 MB pages under competing local work. Page 35 was prewarmed 1.77 s before becoming current but did not reach sourceReady until 1.86 s after current, showing that eligibility is no longer the limiting factor: full READY-as-partial hydration still consumes the shared local-read path before Reader ingress obtains the useful prefix. This is Phase B evidence, not justification to reintroduce role gates.

Reader re-entry memory ownership also behaves as intended in this trace: both retention events report `decodeSessions=0` and `uploadSessions=0`. Physical download/session authority remains retained separately (11 after reader 1 and 33 after reader 2), while hot promoted durable sessions are subsequently pressure-retired by the composition owner.
