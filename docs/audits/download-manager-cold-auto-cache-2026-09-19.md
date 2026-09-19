# Download Manager cold Auto Cache / Canonical first-open audit — 2026-09-19

## Symptom

After a cold process start, opening Download Manager and then the Auto Cache / Canonical tab produced a visible stall even though the route itself already used route-first presentation.

## Root cause evidence

Baseline device trace: `.log/baseline-auto-cache-2026-09-19.jsonl` (exported from `zic-debug-trace-2026-09-19T13-53-48.jsonl`).

The first missing physical-cache projection was hydrated through the full download-management projection. On the measured device state:

- 70 known/visible chapters
- 17,804 visible pages
- 1,020 indexed records
- 118 physical artifacts
- 51 physical partials
- 26 canonical projections
- 1 Canonical row / 8 Exact rows

The full management projection took 322.757 ms. The dominant component was the per-page chapter snapshot rebuild at 287.807 ms; indexed and physical reads were only about 17 ms combined. The complete Download Manager refresh including cache usage was about 417.520 ms.

The cold tab path also started a cache-usage inspection before requesting the missing physical projection, while the full projection refresh performed another usage inspection afterward.

## Ownership boundary

The fix must not:

- move the full management scan back into Home cold startup;
- add a Reader or UI-owned cache/download authority;
- alter NetLane, 7/3 download retention, 2/1 decode behavior, download concurrency, or transfer admission;
- replace the existing full management projection used for durable lifecycle convergence.

Home startup remains limited to its trusted persisted download summaries / targeted revalidation. Full orphan discovery and chapter lifecycle reconciliation remain Download Manager / downloads-owner work.

For the first Canonical presentation only, a caller needs physical Canonical/Exact inventory, not a rebuilt `ChapterDownloadSnapshot` for every page of every chapter.

## Change

A narrow read capability, `ChapterCacheManagementProjectionReader`, now lives in the downloads layer. `PersistentChapterDownloadService.inspectCacheManagement()` reuses the durable artifact index, physical state, orphan grouping, and the existing cache projection builder, but deliberately skips `_inspectManyFromRecords()`.

`HomeLibrarySession.refreshDownloadCacheProjection()` owns the production call and publishes only the cache projection. If a full management refresh is already active for the same service it joins that refresh; services without the narrow capability fall back to the existing full refresh.

Download Manager uses this narrow Home callback only when the Canonical/Auto Cache tab has no physical projection yet. Subsequent durable management invalidations still use the full management refresh. Home owns a management-projection epoch so a full refresh that starts after a cache-only read fences that older read from publishing late and overwriting the newer complete projection. On the missing-projection path, cache usage is refreshed once after the cache projection instead of both before and after it.

## Validation

Post-fix device trace: `.log/after-auto-cache-2026-09-19.jsonl` (exported from `zic-debug-trace-2026-09-19T14-05-07.jsonl`).

On the same stored dataset:

| Metric | Before | After |
| --- | ---: | ---: |
| Full management projection on first Canonical open | 322.757 ms | not executed |
| Per-page chapter snapshot rebuild | 287.807 ms | not executed |
| Cache-only physical projection | n/a | 49.719 ms |
| First Canonical hydration incl. cache usage | 417.520 ms | 146.656 ms |
| Canonical rows | 1 | 1 |
| Exact rows | 8 | 8 |

The measured end-to-end reduction is 270.864 ms, about 64.9%.

Mechanical validation:

- App Download Manager widget suite: 25/25
- Downloads package suite: 437/437 with the repository-required Linux SQLite preload
- affected analyzer: 0 errors, 0 warnings; 18 pre-existing infos

One compatibility regression was caught by the full App suite: a service without a physical cache-projection capability still needs cache-usage inspection to resolve a newer service generation. The tab condition was corrected so only the real missing-physical-projection path suppresses the pre-inspection.

## Remaining boundary

The remaining first-open duration is now dominated by work outside the removed chapter snapshot rebuild, including the independent `ResourceCacheCoordinator` usage inspection. Do not merge that authority into downloads merely to reduce a scan. If user-visible jank remains, profile that owner separately and optimize its own implementation with fresh evidence.
