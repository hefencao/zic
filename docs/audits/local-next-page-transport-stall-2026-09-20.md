# Local next-page transport stall audit (2026-09-20)

## Scope

This audit follows one speculative local-folder Reader failure observed after the animated-cover card CPU fix. It is intentionally separate from the cover change and from Reader window/NetLane policy.

## Historical failure

In `.log/main-card-fix-reader-verify.jsonl`, current page19 presented successfully:

- `pageHostMounted -> firstFrameReady`: about 223ms;
- the later failure belonged to page20, role `next`, priority 820;
- page20 had already restored a 1,048,576-byte durable partial;
- the provider exact id was `local-folder` with an Android `content://com.android.externalstorage.documents/.../00000021.webp` URI;
- three attempts then failed with `transport open stalled: no response within the read stall window`.

The trace field `lane=network` is the generic download scheduling lane and is not evidence that the local page used HTTP.

The underlying file is healthy: `00000021.webp` is 16,176,392 bytes, bytes at the 1MiB resume point are readable, and an adb-shell 1MiB read from that point took about 7ms.

## Owner-path review

Local-folder Reader pages use `LoaderTransportSource.openResponse -> _openLocalMediaResponse -> openLocalImageSource -> LocalMediaBridge.openDocument`.

`LoaderTransport` invokes `openResponse` again for every attempt; it does not retain a failed open Future. Android `LocalMediaBridgePlugin` has a single `zic-local-media` worker for document open/read/close, but during the controlled fresh reproduction that thread stayed sleeping while the Reader was active. There is therefore no device evidence that its FIFO was the historical blocker.

## Fresh exact reproduction

The same local card was re-entered using its accessibility-derived bounds, with no Reader tap/swipe after entry. Fresh `pipeline-reader-2` reused:

- the same exact page20 URI;
- the same `committedLength=1,048,576`;
- the same priority820 speculative role.

This time origin open completed in about 59.4ms and the 16,176,392-byte source stream completed in about 115ms. There were zero retry/taskFailed events in the fresh Reader session.

The restored partial did carry a provider-scoped strong validator, but the current document revision rejected it. DownloadJob therefore correctly recorded:

`resumeRestarted(strategy=full-body-prefix-catchup, strongRangeRejected=true, fullBodyResponseReused=true)`

and safely reused the returned 200 full body while preserving the existing playable prefix. The physical-partial metadata parser only restores a strong validator when both provider DownloadId and validator request URI match the current exact request, so there is no evidence of cross-provider validator leakage.

## Conclusion

The historical page20 open stall is not reproducible and is bounded as a transient local-provider/platform open event. There is no evidence supporting a Reader-window, NetLane, LoaderTransport retry, or LocalMediaBridge concurrency change. No production code is changed for this event.

A separate concrete performance signal was discovered in the fresh trace: page20 exact-fallback durable checkpoint/artifact handoff each took roughly 28.5-28.8s and coincided with `zic-saf-path` work. That belongs to durable storage/handoff ownership and must be investigated independently rather than used to retrofit an explanation for the old source-open stall.
