# Reader loading authority convergence audit — 2026-09-19

## Scope

This audit reviews why Reader loading has remained fragile despite repeated local fixes. The immediate device symptom is vertical static reading where a page is already available from cache, yet the Reader still shows the grey transfer bar / a new load attempt and can occasionally fall back to the circular page-loading indicator.

The audit distinguishes **multiple byte/pixel carriers**, which are legitimate, from **multiple lifecycle authorities for one visible page**, which are not. A native WebP stream, an immutable static file lease, resident replay, a hot session artifact, and a Flutter ImageProvider can all be valid carriers. They become fragile only when more than one layer independently decides whether the page is “loading”, whether its current generation is still usable, or whether an already-presented image must be retired.

Primary device evidence: .log/zic-debug-trace-2026-09-19T12-15-05.jsonl.

## Device evidence: cached presentation is followed by destructive background refresh

The latest Profile trace contains 323 presentation/source reads. Local work is not generally blocked: the shared local-read scheduler wait is p95=0, with 219 presentation-file-lease reads and 62 resident-replay reads. The visible anomaly instead tracks historical-carrier revalidation.

For a representative cached static page (page 98 / physical identity identity:<-24a99312606eac8,572>):

- Pipeline classifies PNG with localPresentationReady=true.
- Resident presentation reads 244,125 bytes in 2.029 ms, then again in 0.940 ms for mounted presentation.
- external-static-mounted-image-frame reports a synchronously available frame.
- Roughly 0.5 ms later composition starts historical-carrier-revalidation.
- presentation-artifact-recovery reuses the destructive recovery primitive with reason historical-carrier-stale-while-revalidate.
- Pipeline immediately observes source-epoch-changed, invalidates one decode and one upload, and clears external-presentation satisfied/pending state.
- The same physical DownloadSession resets to idle and fresh-source local preparation reports local-hydration-miss.
- Existing demand is then re-admitted to network.

This is not an isolated offscreen sequence. Matching current page identities found 25 current-page cases where a cached mounted static frame was followed by the same historical-revalidation -> physical reset -> fresh downloadStarted sequence. The Reader progress indicator selects the current physical DownloadSession directly, so this background convergence is necessarily rendered as foreground loading/connecting activity.

## Confirmed ownership gaps

### 1. “Stale-while-revalidate” currently uses a destructive presentation-recovery primitive

CompositionDownloadTransferRuntime._startHistoricalCarrierRevalidation() calls recoverPresentationArtifact(). The same primitive is also used for a presentation that actually rejects corrupt/invalid bytes, an explicit user force-reload, and historical cache stale-while-revalidate.

The first two operations intentionally invalidate the old presentation generation. The third operation must do the opposite: keep the admitted stale presentation usable while fresh exact authority converges in the background.

DownloadTransferOwner.recoverPresentationArtifact() cancels local/network work, invalidates the chosen durable authority, resets the physical DownloadSession epoch, clears prepared state, and re-admits existing demand. That is correct recovery behavior for rejected bytes, but it is not presentation-preserving stale-while-revalidate.

The existing regression test currently codifies the wrong semantic boundary by asserting that the resident historical presentation must be retired immediately after the first frame.

### 2. Transfer progress is a raw physical-session projection, not a page-loading projection

PipelineTransferProgressPublisher selects the current physical DownloadSession and publishes queued/receiving/partial state. ReaderTransferProgressIndicator then renders that state as the page’s grey connecting bar / transport wave / partial line.

It has no input stating that the exact external-static presentation identity has already produced a visible frame. Therefore a background revalidation or durable convergence task on the same current physical session is visually indistinguishable from “the page is still loading”.

The correct boundary is one-way: the progress UI may project unsatisfied foreground transfer, but a completed static presentation must not become transport policy. Suppression belongs in the Pipeline read-only projection, not in Reader, DownloadSession, or NetLane.

### 3. Historical artifact identity is discarded at the resident-bind seam

ArtifactCacheManager.lookupHistoricalCarrier() has the exact selected storageId + mutation generation. PartialDownloadHandoff converts that selected artifact to a generic PartialDownloadEntry and binds only range replay/checksum facts into DownloadSession.

The resulting resident session knows how to replay the immutable bytes but no longer knows which exact persistent historical artifact generation was admitted by policy. Once revalidation resets that DownloadSession, Pipeline cannot legally reopen the just-presented stale artifact during fresh-source quarantine.

The durable historical body still exists, but requiresFreshSource(currentId) intentionally blocks normal cache/equivalence/historical candidate routing. Continuity therefore depends on whether the previous LocalImagePlayer / Flutter ImageCache still happens to retain decoded pixels or bytes. A widget remount, lease release, cache eviction, or presentation-generation change can expose a spinner even though the stale durable artifact still exists.

This is a true authority-loss seam, not merely a missing retry.

### 4. LocalImagePlayer combines three projections whose lifetimes can diverge

LocalImagePlayer simultaneously consumes PipelinePageStream for source kind/source dimensions/failure, PipelinePageOutput for native/external presentation permission and output state, and local _state/_imageProvider/_bytes for the actual Flutter renderer.

This composition is acceptable only while Pipeline owns the generation transitions. It becomes fragile when an unrelated background revalidation resets PageStream generation after a valid Flutter provider has already been established. Small changes to widget retention, ImageCache identity, descriptor lifetime, or output rebind then decide whether the old pixels survive.

The previous generation-gate fix e7df1e22 correctly removed one widget-lifetime authority; it does not solve the upstream destructive revalidation contract.

## Legitimate carrier paths that should remain

The goal is not to force every image through one byte API. The following paths solve different media/storage constraints and can remain:

- WebP native streaming -> decode -> upload/present surface;
- eligible non-WebP durable static -> generation-checked encoded presentation file/descriptor lease;
- immutable resident READY -> range replay / bounded metadata then presentation bytes;
- hot promoted session artifact -> session/cache read;
- controlled GIF / fallback static -> external Flutter presentation;
- detached ImageCache prewarm -> later mounted presentation using the same exact external-presentation cache identity.

They must all be selected under one Pipeline presentation contract rather than each becoming an independent “is loading” authority.

## Target convergence

### A. Presentation-satisfied transfer projection

Pipeline should suppress the Reader transfer-progress feed once the current external-static page has produced a real visible frame. A source-epoch/presentation-identity rotation caused specifically by stale-while-revalidate does not revoke that satisfied projection while the exact retained historical presentation authority remains valid; the page still has a legal drawable body even though fresh transfer convergence has started. Raw DownloadSession state remains unchanged and all background work continues. Manual force reload, real presentation failure, page change, or an identity rotation without retained presentation continuity must remove suppression. Animated/partial WebP progress remains unchanged.

This removes false loading UI without making first-frame state a transport scheduler input.

### B. Retained historical presentation authority

When cache policy admits one historical READY carrier, ArtifactCacheManager should retain only the exact selected persistent authority tuple (current logical id -> historical storageId + generation) as transient presentation continuity state.

During fresh-source quarantine, normal cache/source/equivalence routing must still reject stale bytes. A separate narrow presentation-only exact-authority open/read may reopen only that already-admitted storageId at the same mutation generation. It must not search candidates, register equivalence, create a current exact binding, satisfy DownloadSession restore, or influence NetLane.

The continuity authority should be retired when fresh exact recovery completes, recovery is cancelled, the selected historical storage generation changes/disappears, or policy stops allowing reuse.

This preserves one physical transfer/session/writer owner while making stale presentation continuity explicit instead of relying on Flutter ImageCache lifetime.

### C. Keep destructive recovery explicit

recoverPresentationArtifact() remains the correct primitive for semantic presentation rejection and manual force reload. Historical stale-while-revalidate may still reset the transfer session to obtain fresh exact bytes, but that reset must no longer implicitly revoke the already-admitted presentation-only stale authority.

Longer term the method naming/API should distinguish destructive recovery from background convergence so future callers cannot accidentally inherit the wrong semantics.

## Regression invariants

1. Cached external-static visible frame followed by historical revalidation may start fresh network work, but the Reader transfer-progress projection stays empty for that already-satisfied presentation identity.
2. If the static page widget is disposed/remounted while fresh-source quarantine is active, presentation can reopen only the exact previously admitted historical storage generation and must not wait for fresh source merely to redraw stale content.
3. A mutation of that historical storage generation invalidates the presentation continuity capability; no stale generation is silently reused.
4. Fresh exact promotion retires the retained historical presentation capability.
5. Manual force reload and semantic presentation failure remain destructive and do not consume retained stale presentation as recovery.
6. Historical reuse remains routing trust, not equivalence/canonical/current-exact proof.
7. No Reader/UI retry owner, second DownloadSession, second NetLane task owner, or parallel cache lookup policy is introduced.
8. Animated/partial WebP transfer progress and existing 7/3 download, 2/1 decode, static one-frame staging, and local-read scheduler limits are unchanged.

## Why loading has felt unusually fragile

The repeated regressions have mostly occurred at **authority handoff seams**, not because individual decoders or transports are inherently unreliable. Several optimizations correctly removed large copies or reduced latency, but the old lifecycle assumptions remained:

- durable READY moved from copied session artifacts to resident replay, while presentation code still sometimes assumed hot session bytes;
- external static moved to staged Pipeline grants, while UI previously kept widget-lifetime load state;
- historical URI reuse gained a trust policy, while stale-while-revalidate still reused the same destructive reset path as corrupt-byte recovery;
- progress UI was split from transport ownership, but it still projected raw current-session activity as if it were presentation loading;
- provider/file/ImageCache acceleration preserved pixels across some resets, accidentally hiding the missing stale-presentation authority.

As a result, a change that alters timing, widget retention, cache identity, or descriptor lifetime can expose a different seam. The durable fix is to make every cross-layer handoff carry the minimum exact authority needed by the next layer and to keep background convergence facts out of visible-loading projections.
