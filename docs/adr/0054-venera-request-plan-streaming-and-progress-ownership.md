# ADR 0054: Venera request-plan streaming and progress ownership

Status: Accepted in `0.31.0-dev.70`.

## Context

dev.65-dev.69 treated Venera `loadResource` as a complete-byte RPC or reduced the Reader window to avoid failures. That erased chunk progress, delayed first-frame ingress, made completed-page progress flicker, and incorrectly coupled source callback execution to body ownership. The uploaded VibeVenera implementation demonstrates the intended split: source code resolves an image request configuration, while a shared streaming transport/session owns network bytes, partial artifacts, resume and UI projections.

## Decision

1. Add optional catalog capabilities for resolving and retrying `ComicResourceRequest`.
2. Keep JavaScript request-plan invocations serialized. Stream ordinary HTTP(S) bodies in the host through `ExternalPluginResourceTransportPool` and the existing `DownloadSession`.
3. Preserve a stable +7/-3 download window, +2/-1 decode warm window and current/transition upload window with independent 5/3/2 lanes.
4. Keep normal receiving downloads alive when demand detaches. Explicit cancel/dispose cancels the response subscription.
5. Project chapter and current-page progress from DownloadSession snapshots. Projection failures cannot fail the writer; promoted/restore sessions remain visually idle.
6. Permit complete runtime body fallback only for explicit `onResponse`/`modifyImage` transforms.
7. Redact opaque Venera locators in trace at event construction.
8. Deduplicate only the demand role map. Viewport/playback coverage still updates for every Reader observation, and transport pooling is keyed by source object identity so replacing a wrapper cannot close an active Reader connection.

## Consequences

- Predownload is restored without restoring full-body plugin RPC.
- First chunks reach artifact/ingress and progress UI before body completion.
- Source request configuration remains compatible with Venera callbacks and cookies, while cache/resume/decode ownership stays in ZIC.
- Transforming sources are slower by design but isolated from the ordinary path.
- Demand stability no longer freezes transition playback, and source-registry wrapper replacement cannot tear down an in-flight response owned by another session.
