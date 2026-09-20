# Cold WebP first-frame / Venera request-plan audit (2026-09-20)

## Scope

This audit follows the final page before Reader exit in `zic-debug-trace-2026-09-20T03-00-33.jsonl` and separates it from the stale local-restore cancellation fixed by `8c7ac8b5`. It does not change Reader windows, decode/upload concurrency, NetLane, local-prepare capacity, or Venera runtime concurrency.

## The actual slow page

The final exited page is zero-based page 383 in `pipeline-reader-2` (displayed page 384/424). It mounts at 498.638s, becomes current at 499.001s and publishes first frame at 501.260s: mount-to-first-frame is about 2.622s and current-to-first-frame about 2.258s.

Its physical local preparation is already fast (~21.6ms). The source task was admitted earlier as next2 and migrated 800→820→900→1000. Total request-plan gate wait is ~2.626s, but most of that occurred while the page was still speculative behind the physically single Venera JavaScript invocation. Once the viewport commits page 383 current, the gate hands over in roughly 30ms. This is therefore not a stale-current or priority-migration defect.

The first successful request plan is a legitimate cache miss. Its own runtime invocation is ~573ms and host open ~584ms. The source hook performs three cache hits plus one origin POST in the representative warm case; the page body is about 14.9MiB.

## Encoded-prefix and decode timing

The older trace appeared to leave an unexplained delay between `decodeStarted` and `decodeState=decoding`. A fresh Profile build added three fields to the existing decoding-state event only: `cursorReused`, `cursorCreateMicros`, and `sourceLength`; no new trace event or scheduling behavior was added.

On the same Ani 371-page Reader, a controlled SeekBar jump 63→324 reproduced a cold nearby WebP. At 8KiB the decoder actually runs and returns `needMoreData(nextSourceLength=262144)`. Intermediate source growth below that learned threshold returns immediately to waitingSource. Once the source reaches 278528 bytes, `decodeStarted`→`decodeState=decoding` is ~59µs, `cursorReused=true`, `cursorCreateMicros=0`. The two native frame decodes are roughly 41–44ms each with microsecond-scale worker queue/ready times. The initial cursor creation observed in the same run is only ~1.6ms.

Therefore the apparent older ~462ms gap was trace coalescing hiding the final sufficient-source wake, not cursor creation, DecodeLane starvation, UI-isolate blocking, artifact write, or ingress publication delay. More frequent wakeups would only retry a prefix the decoder has already proven insufficient.

## Fresh source-plan convoy

The same fresh Profile trace shows why speculative 3/7 work can still arrive late after a large seek even though it starts early:

- page324 / next: gate wait ~23ms, runtime invocation ~1.583s, bridge network ~1.524s; 2 cache hits + one origin GET + one page-specific origin POST.
- page325 / next2: gate wait ~1.578s, runtime invocation ~488ms; 3 cache hits + one origin POST.
- page326: gate wait ~2.478s, runtime invocation ~492ms; 3 cache hits + one origin POST.

The installed `venera:ehentai` source explains this shape. `onImageLoad` calls `loadThumbnails(comicId)`, `getKey(first.urls[0])`, optionally another thumbnail-page load, then performs the unique `imagedispatch/showpage` POST. Both common GET helpers already declare source-owned `cache-time: long`; crossing a new thumbnail batch may add one origin GET. ZIC already preserves that cache in the single `NativeExternalPluginDriverHost` Venera cache owner and separately caches successful exact request plans for 10 minutes.

## Why runtime concurrency remains one

The Android driver can keep multiple native result objects in a map, but the source JavaScript contract still relies on one active invocation identity. `sendMessage`, delay cancellation, bridge waiter cancellation, resolver freshness and bridge metrics derive request scope from global `__zicActiveRequestId`. dev.183 previously proved that admitting a replacement request before the cancelled JavaScript promise physically reached `finished(requestId)` allowed two promises to overlap and made the request-scoped Network bridge unsafe; dev.187 completed cancellation of delay/bridge waits around that same boundary.

The current gate therefore remains a physical single-invocation contract, not an arbitrary performance knob. Raising it to 2 would reintroduce cross-request cancellation/diagnostic identity corruption. VibeVenera likewise invokes each source's `onImageLoad` as the source contract; its code does not provide a host-level gallery/key business cache that ZIC can safely copy. ZIC must not infer ehentai-specific `loadThumbnails/getKey` results or pre-resolve a whole chapter behind the source's back.

## Result

No additional Reader/Pipeline scheduling defect is established by this cold-page trace. The remaining cold tail is dominated by first-time source request-plan work, source-declared network calls, direct host open, arrival of the decoder-required prefix, and normal native decode. Future work should only reopen this boundary if a fresh trace shows current-class gate handoff itself regressing, source-declared long-cache hits unexpectedly becoming origins, or a source/runtime contract change provides safe request-scoped async identity. Do not compensate by shrinking 3/7, changing 2/1, raising Venera invocation concurrency, or creating a host-owned ehentai/gallery cache.
