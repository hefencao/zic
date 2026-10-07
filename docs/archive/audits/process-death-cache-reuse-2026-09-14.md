# Process-death cache reuse audit — 2026-09-14

## Question

Recheck the user-visible claim that leaving/killing the app appears to lose cache and causes pages to download again. The test must not use Reader/App exit-time checkpointing as the proof: kill the process while Reader is active, then cold reopen the same history entry and separate READY reuse from incomplete-partial transport behavior.

## Device setup and pre-kill facts

Current profile was already installed with `adb install -r`; data was preserved and `low_power=0`. The durable store is schema 17. Before the test the DB contained 74 physical READY artifacts and 43 physical partials. The selected Ani Collections history entry opened at pageIndex 32 (UI 33/371).

The current-family page32 physical READY body was App-private and exactly **15,244,686 B** (`artifact_id=00d7afbc3e6d1624`, `.../offline_chapters/final/2a05b18543b8634b.bin`). Adjacent page31 had an App-private durable physical partial of exactly **6,809,440 B** (`.../offline_chapters/partial/15898ea7ef737f3e.part`).

## Hard process boundary

While Reader was still active, `adb shell am force-stop dev.zic.zic` was issued. No Reader Back, App close hook, or graceful runtime drain was run first. Immediately after the process disappeared, both files still existed at exactly the same lengths: page32 READY 15,244,686 B and page31 partial 6,809,440 B. This directly rules out force-stop itself deleting these durable bodies.

## Cold-reopen trace

After launcher cold start, the same history card reopened pageIndex 32. Exported trace:

`.log equivalent: /sdcard/Download/Debug/zic-debug-trace-2026-09-14T05-09-05.jsonl`

Pulled audit copy: `/tmp/zic-restart-check/restart-trace.jsonl`.

For page32 the trace shows `artifactPromoted(length=15244686)` followed by `physical-local-prepare / local-completion-short-circuit` with `committedLength=15244686` and **`networkAdmissionRequired=false`**. No provider network attempt was required for that page. READY cache therefore survives a real process death and is reused locally on cold Reader re-entry.

For page31 the new process first recovers the existing prefix, not zero bytes: `durable-partial-adoption / adopted-posix-spool committedLength=6809440`, `adopted-physical bytes=6809440`, then `physical-local-prepare / local-hydration-ready committedLength=6809440`. Only after that does the owner report `networkAdmissionRequired=true`, because the encoded body is incomplete.

The validatorless resume probe starts at **6,743,904 B**, exactly 64 KiB before the preserved 6,809,440 B boundary. The downstream response is **HTTP 200**, not 206, with total length 15,860,380 B. At prefetch priority 780 the job therefore keeps the local prefix and reports `full-body-prefix-catchup-deferred`; when the page later becomes current it reuses a full-body response for the existing continuity/catch-up path. This duplicate network prefix is not cache loss: the local committed boundary remains 6,809,440 B and is the continuity authority throughout.

## Range-path check

The production request path does not provide evidence that zic strips the Range request. `normalizeSourceResourceRequest(...)` inserts `Range` into the normalized `ComicResourceRequest` for an entityless GET/HEAD, and `RhttpSourceResourceDirectTransport.open(...)` passes the complete `request.headers` map to `rhttp.HttpHeaders.rawMap(...)`. The trace also records the attempted `rangeStart=6743904` while the returned source response is status 200 / range unsupported. Therefore this audit does not justify weakening continuity checks or inventing a second retry path; the safe full-body catch-up remains required when the downstream response ignores the range.

## Conclusion

The original symptom has two materially different cases:

- **READY page:** process death does not remove it; cold re-entry is local-only and needs no network admission.
- **Incomplete partial:** process death does not remove the prefix; it is restored exactly, but the missing suffix still needs transport. If the downstream source responds 200 to the overlap/range request, already-cached prefix bytes can be retransmitted on the wire while still being preserved locally and content-checked.

No Reader/App lifecycle persistence hook was added. No code change is required from this process-boundary audit; the current ownership split is behaving as designed.
