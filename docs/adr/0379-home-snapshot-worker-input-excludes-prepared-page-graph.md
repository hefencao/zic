# ADR 0379: Home snapshot worker input excludes prepared page graph

Status: Accepted

## Context

Current Profile URI allocation tracing records14,692 URI objects copied on
the UI thread in one `Isolate_spawnFunction` window. The encoder's bound
receiver retains the entire HomeProjectionSnapshot, including initialized
record-local manifests. Ordinary chapter entries persist compact metadata
and pageCount, so those page models and prepared URIs are unused input.

This proves redundant allocation, not that every Reader GC frame has this
cause. One matched long frame precedes the copy window. Instrumented timing
does not establish ordinary Release performance or physical presentation.

## Decision

The existing storage owner prepares the snapshot's persisted field projection
before handoff. The input map retains immutable durable catalog/preference/
read-state DTOs whose toJson conversion runs on the existing encoding worker.
Orphan fields retain raw page DTOs, excluding prepared manifest state; ordinary
entries contain only compact metadata. JSON encoding and compression stay
on that worker. Full orphan download metadata,
schema4, serialized writes, completion barriers and temporary-file replacement
retain their current behavior. Prepared chapter projections stay reusable
on their current owners, with no new cache, worker, queue or Reader state.

The caller does compact entry projection instead of cloning the full reachable
model graph. The first candidate eagerly called the full snapshot.toJson on
the caller and moved large SavedComic chapter projection to UI; matched CPU
sampling identified6–8 inclusive ticks and that candidate was rejected.
Large catalogs, version mappings and orphan metadata still need
device measurement; this decision does not claim to eliminate all allocation.

## Validation

A consistent prepared chapter in an immutable owner-bound list fails before
the change: its nonpersistent ReceivePort is accidentally sent to the worker.
The regression passes after projecting only persisted fields and verifies
compact primary entries, exact orphan page locators and retained manifest
identity. Final gate2208/Rust22, three-ABI Profile/Release, matching Profile URI-copy0
with main SavedComic.toJson ticks0, and ordinary8323-event regression checks
pass for this scoped input contract. Independent performance remains open.

Evidence: `docs/audits/home-snapshot-worker-input-allocation-2026-10-03.json`.
