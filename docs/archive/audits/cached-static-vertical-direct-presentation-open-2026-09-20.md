# Cached static vertical: Direct presentation-open executor root cause (2026-09-20)

## Symptom

An already-cached static vertical chapter intermittently looked as if pages were downloading again: page placeholders/loading remained for seconds even though the content had previously been cached.

## Trace classification before edits

The exported reproducer is `pipeline-reader-7` in `.log/zic-debug-trace-2026-09-20T00-00-20.jsonl` / `00-01-26.jsonl`. Its transfer owner did **not** re-download the static pages: 92/92 local preparations ended in `local-completion-short-circuit`, there were zero `downloadStarted` events and zero `source=origin` reads. All 157 presentation reads came from persistent `artifact-cache`.

The actual stall was inside the cached presentation lease. In the shorter cold trace the first 11 `presentation-file-lease` reads had median **4.93 s** and maximum **5.74 s**; later warm reads fell to millisecond scale.

Device `chapter_downloads.sqlite` plus WAL/SHM was copied read-only and inspected. The same `venera:jm` population contains **720 READY** cache rows. The affected artifacts are under the App-private Direct root `/data/user/0/dev.zic.zic/files/zic/offline_chapters/final`, even though the user-selected explicit download directory is SAF. Therefore the active bridge method is `presentationOpenDirect`.

## Root cause

`MainActivity.handleSaf()` historically routed SAF read opens and `presentationOpenSaf` into a 4-thread read-open executor, but `presentationOpenDirect` fell through to the single-thread `zic-saf-path` executor. That executor is intentionally the serialized owner of SAF tree/path resolution and namespace mutation. A normal App-private cached-file descriptor open therefore sat behind unrelated path work.

This was an executor-ownership classification bug in the Android platform bridge, not a Reader cache miss, NetLane retry, waterline problem, or a second network download.

## Fix boundary

Read-only opens are now one platform execution domain: read `safOpen`, read prewarm, `presentationOpenDirect` and `presentationOpenSaf` use the bounded four-thread `zic-local-read-open-*` pool. `zic-saf-path` remains the serialized path/tree/namespace owner, and already-open descriptor operations remain handle-striped. Persistent cache proof and Dart `ArtifactCacheReadScheduler` authority are unchanged.

## Device validation

Fresh Profile APK installed with data preserved, using the same durable cache. `.log/zic-debug-trace-2026-09-20T00-12-57.jsonl` contains zero `downloadStarted`, zero origin reads and 19 cached presentation-file leases with min **4.76 ms**, median **15.12 ms**, p90 **19.91 ms**, max **31.96 ms**. Pipeline maximum revision is 15.

A separate Reader-only main-thread CPU cost remains under audit: after presentation has settled, Profile sampling still showed roughly 25% on the app main thread while a five-second Android framestats window contained no continuous draw frames. That is intentionally not treated as evidence of network re-download and is not patched by this change.
