# ADR 0346: Mounted presentation cache admission

- Status: Accepted
- Date: 2026-09-30

## Context

Fresh Profile verification of slider repairs exposes a residency feedback loop. The retained 10,000 events in `zic-debug-trace-2026-09-30T11-18-13.jsonl` span 94.047 seconds and contain 1,161 presentation file reads, including 1,137 repeated-identity pairs under five seconds. Far raster invalidation explicitly reports `presentationWarmAllowed=false`, followed by another mounted first-frame grant and read.

Pipeline checks the cache authority's admission decision for detached prewarming, but `_externalPresentationAvailable` previously accepted any mounted listener first. Sliver/PageView composition retains offscreen PageHosts. When a satisfied page is evicted, another first-frame acknowledgment wakes staged refill and the mounted listener bypasses denial, repeatedly recreating the same budget victim. This does not represent new origin downloads.

## Decision

Mounted first-frame availability must consume the existing presentation-cache authority's `allowsPresentationWarm` decision, just as detached prewarming does. A mounted listener is consumer availability, not resource admission authority. Keep the same identity, claim projection and scheduler. Deadline/protected promotion clears the owner's existing denial and may refill the same source/fit generation.

Do not add a Pipeline eviction tombstone, poll cache residency, enlarge the 100MiB/1000-entry envelope, or transfer admission to Reader. Network eligibility and all encoded/decode/upload windows remain unchanged.

## Validation

Extend the existing eviction/promotion regression with two mounted far outputs. Before repair, evicting both budget victims regrants the denied page; the requested=false assertion fails. After repair the denied pages stay unrequested and promotion refills the same cache identity. Reader and Pipeline ownership suites pass 72/72. Final toolchain/device evidence is in `docs/audits/slider-mounted-cache-admission-2026-09-30.json`.

The final-source required-toolchain gate passes. The complete `11-56-26` Profile trace records zero regrants for both denied far identities during approximately 74.789s of idle before the next scrub. Its 28 presentation reads cover 26 identities, with two short repeats during rapid role handoff and no further reads after the selected current's first frame. The sustained idle eviction/regrant/reopen loop is absent; short repeats are retained in the audit rather than reported as zero.
