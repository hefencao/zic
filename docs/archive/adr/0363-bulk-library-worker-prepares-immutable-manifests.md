# ADR 0363: Bulk library worker prepares immutable manifests

Status: Accepted

## Context

A separate startup capture records an 87ms canonical-authority build.
Of 66 main-isolate samples in that owner call, 64 include first manifest
construction and 62 include page URI parsing. The persistent bulk library
read already owns a short-lived read-only isolate, but transfers records
before their lazy manifest projection has been initialized.

## Decision

That existing worker initializes each returned record's immutable manifest
after SQL/JSON model decoding and before transferring the completed models.
The record-local projection is reused by Home's current canonical/version
authority builds. Runtime authority publication stays on its existing owner.

No additional worker, cache, queue or scheduler is introduced. The admitted
bulk-read future still includes all preparation, and close joins its physical
retirement. SQLite connections do not cross isolates. Exact reads, explicit
backup transactions and in-memory bulk event-turn behavior remain unchanged.

## Validation and limits

The pre-change Profile capture is the performance regression evidence.
Storage focused43 passes: bulk close joins, malformed decode errors reach
the caller, a large row remains off the caller, and transferred opaque,
signed and file URIs retain page metadata and an immutable reused manifest.
Required gate2164/27 + Rust22 and ordinary minified Release pass. For84 entries,
matching startup Profile canonical build changes87ms to5ms and scoped samples
66 to5, with no manifest/URI parser in the latter owner samples. Ordinary
Release startup build is3ms. CPU work stays inside the existing bulk read;
these figures do not claim less total CPU or faster complete startup.
Startup download/cache projection costs and final display remain separately
scoped; this decision does not change cache/physical proof or native workers.
See `docs/archive/audits/loading-chapter-plugin-regressions-2026-10-01.json`.
