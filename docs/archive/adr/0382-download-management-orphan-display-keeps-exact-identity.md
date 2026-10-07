# ADR 0382: Download management orphan display keeps exact identity

Status: Accepted

## Context

Manual offline downloads can outlive their library metadata. Orphan discovery
previously used source-owned comic and chapter IDs as display labels. The safe
metadata projection for automatic cache rows did not cover manual snapshots,
persisted cold Home summaries or delete-confirmation text.

The IDs still identify durable bindings and mutation targets. Decoding a plugin
payload to invent a title would couple download management to a source model.

## Decision

The downloads owner derives display aliases from supplied current library
metadata using the existing source/comic/chapter coordinate. Both manual
inspection and cache management use the same invocation-local selector. An
orphan without matching metadata receives generic comic/chapter labels; older
orphan entries containing identity-as-title are handled identically.

Download Manager uses known entry metadata or safe labels for old cold summaries
and delete confirmations. Raw source IDs are removed from ordinary task
subtitles. Display selection does not modify the original command snapshot,
exact revision, manifest, READY/pin/progress or delete identity. No payload
parsing, body scanning, additional persistence or scheduling owner is added.

## Validation

Failing-first owner and cold widget cases reproduce the legacy labels. The
widget also exposes the old label in delete confirmation while bulk refresh is
blocked. The candidate passes these cases and the download/app owner suites.
Required gate2217/27 suites/Rust22 and three-ABI Profile/ordinary Release
builds pass. Packaged Dart markers and JNI/FFI/AGP strip consistency match.
Ordinary Release shows safe manual labels and the same5-page/1.3MiB offline
record; delete-impact preview shows5 exact bindings and is dismissed without
mutation. Automatic cache rows retain their existing human labels. The separate
chapter19/20 cache/loading report remains under investigation.

Evidence: `docs/archive/audits/user-repeated-download-loading-regressions-2026-10-03.json`.
