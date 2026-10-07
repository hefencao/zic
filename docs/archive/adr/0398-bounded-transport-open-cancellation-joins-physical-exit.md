# Bounded transport open cancellation joins physical exit

Status: Accepted

## Context

The actual source-runtime resolver Pipeline fixture physically closes its held
TCP response on route teardown, but the source delegate has not completed when
the composition reports an idle NetLane. The v2 observer records no delegate
error at that boundary. This is distinct from the earlier accepted source
failure/retry fixture and does not implicate its retry policy.

DownloadJob races scheduler cancellation against its pending open. A bounded
source invocation can still be unwinding when that race completes the task.
ArtifactCacheTransport independently races the same signal against its origin
open, so joining only the outer DownloadJob Future would not fix the boundary.
Four deterministic NetLane tests and two Reader wrapper tests fail before the
repair: capacity/outer completion retire while lower work is still gated.
The first unit fixture run had a test compile error and is excluded from this
production failing-first evidence.

## Decision

Keep cancellation on the original scheduler control. When an open already has
SelfBoundedOpenTransport proof or has reported the existing bounded phase
handoff, DownloadJob joins its original pending Future and any late response
discard before returning the cancellation result. ArtifactCacheTransport joins
the same lifecycle when forwarding a proven bounded fallback.

Unproven legacy opens retain their generic watchdog and late discard behavior.
No additional timer, scheduler, admission gate, retry owner, cache authority or
Reader state is introduced. Finite deadlines remain owned by the existing
source runtime and direct transport. Body-read inactivity, priority, original
attempt budget and local-stage watchdog behavior stay unchanged.

## Verification and limits

The six regressions pass after the repair and cover bounded/phase-handoff
opens, lower failure, late response discard, key retirement and subsequent
NetLane admission. Existing focused DownloadJob and artifact-cache transport
suites pass 46 and 36 tests. All four actual source-runtime resolver Pipeline
cases pass through source/Service/Binder/rhttp: typed transient retry succeeds,
three attempts exhaust once, active cancellation joins in 39,802 microseconds,
and retry-backoff cancellation joins in 18,385 microseconds. Cancelled work
produces no late resolver/media request, durable READY or frame in six seconds.

All2295 Dart/Flutter tests,27 suites/analyzers,22 Rust and108 Android tests pass.
All three ordinary Profile/minified Release ABIs and three fixture ABIs match
the source snapshot and unchanged native libraries. The ordinary Release runs
six stationary cached chapter19/20 slider/edge steps:116 cache reads, no
download/failure and actual content at1s/6s. Independent fixture backups keep
all120 chapter/URI/progress records exact; subsequent real Reader actions only
update chapter19/20 reading state and export time. Full evidence is in
`docs/archive/audits/source-runtime-network-pipeline-2026-10-05.json`.
This repair does not establish the cause of the original intermittent
chapter19/20 loading, GC/input latency or final physical presentation.
