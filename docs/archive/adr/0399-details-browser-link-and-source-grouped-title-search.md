# 0399: Details browser link and source-grouped title search

Status: Accepted

## Context

Venera JM declares its JavaScript update file as source.url. Resolving a numeric comic ID against it opens a nonexistent file in the configuration repository. The accepted canonical identity also uses the existing resolver, so a global replacement would churn persisted aliases and cache identity.

The details metadata-search command exits to the original single-source page. A title search needs a separate route that preserves the details and displays independently completed results grouped by source rather than plugin.

## Decision

Use a browser-only JM adapter projection: numeric or jm-prefixed IDs map to https://18comic.ink/album/<id>, and valid absolute HTTP(S) IDs remain unchanged. Keep the existing canonical resolver and source website projection. The current ordinary same-comic Mihon browser uses this domain; the initial .vip candidate is retained in the audit with its device verification failure.

Add a distinct details title command and ComicTitleSearchPage. After the first frame, request source publication from the existing external-source lifecycle and consume its read-only projection stream. New enabled searchable source IDs join the current query without restarting existing groups or pagination; use the original browse API, canonical page projection and artwork loader. Each group holds a read-only request Future. Submission, pagination and explicit retry create requests; rebuilds do not. Old-query and disposed-route completions do not publish. Source cancellation and runtime retirement remain with the original owners.

The current comic result returns to the existing details State; other results use the original details entry. Metadata tags still select the original source and query, retiring the nested details/search routes to the Home route first. The source page's existing aggregate and query-lock behavior remains intact.

## Consequences and validation

No Reader, scheduler, transport, cache authority or plugin-script changes. Browser addresses do not become comic identity. Independent completion avoids a barrier across fast, slow or failed sources.

The original JM link and deferred-roster omission fail before repair. Adapter59 and six search tests cover canonical identity preservation, progressive source publication, stale completion, explicit retry, raw pagination coordinates and nested tag routing. Required2304 tests,27 suites/analyzers and Rust22 pass; native108 is reused against unchanged Android inputs and identical packaged native/Dex files. All six ordinary Profile/Release APKs match the643-input snapshot. Cold ordinary Release verifies six source groups, original-result return, nested details/tag routing and the normal JM site at18comic.ink. Six cached chapter19/20 stationary slider/head/tail steps have118 artifact-cache reads and no download/failure. All122 complete chapter payloads/URIs/revisions/importedAt remain identical; only actual19/20 progress timestamps and export time change. The original intermittent loading, GC/input latency and final display remain outside this decision; see docs/archive/audits/details-web-title-search-2026-10-05.json.
