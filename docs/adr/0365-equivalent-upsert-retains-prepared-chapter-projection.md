# ADR 0365: Equivalent upsert retains prepared chapter projection

Status: Accepted

## Context

The accepted ordinary Release retains a25.794ms next-entry build. A matching
previous-to-next Profile run records a24.122ms build with4 of9 scoped samples
in first manifest construction and page URI parsing. Preparation has already
initialized the incoming chapter manifest, but the exact durable post-upsert
read decodes another record and loses that prepared immutable projection.
Reader build then parses the198-page chapter again. The existing bulk worker
and adjacent-query fixes remain verified and do not cover this exact-read path.

## Decision

HomeLibrarySession retains the durable upsert/get and current-store adoption
loop. After the exact read, it compares every persisted chapter value, including
metadata, timestamps, ordered pages and exact provider carriers. An equivalent
record is replaced by the incoming immutable chapter object, retaining the
store-returned current progress. A real changed payload uses the readback record.

The existing unchanged-authority comparison uses the same full-value predicate,
without JSON serialization or manifest construction. Authority publication and
canonical assimilation keep their synchronous owner and ordering. Record-local
projection lifetime remains ADR0358; no cache map, worker, queue, network gate,
budget, native lifecycle or scheduler change is introduced. Exact reads and
SQLite transactions remain on their existing narrow path.

## Validation and limits

Real SQLite failing-first observes a different returned manifest despite an
equivalent prepared record. Two regressions cover projection identity, durable
progress, mounted/version projections, and concurrently changed stored metadata,
page order and page payload. Home/Reader/version focused92 passes. The first
fixture used the nonexistent ReaderMode.vertical and failed to compile; that
attempt is excluded from product evidence. The corrected continuous-mode test
fails on projection identity before the production change.

Required gate2170/27 + Rust22 passes. Matching previous5-tail to next6 Profile
build changes24.122ms to4.777ms; manifest/URI inclusive samples change4/9 to0/5.
Ordinary minified three-ABI Release builds; matching installed hash and a complete
4104-event export verify first/last entries and main-list version/ABI, taskFailed0.
A separately observed semantic endpoint velocity jump remains outside this
projection contract. This scope does not establish final presentation,
visual smoothness or remove independent entry/catalog costs. Evidence is in
`docs/audits/loading-chapter-plugin-regressions-2026-10-01.json`.
