# ADR 0362: Invocation-local logical chapter sort keys

Status: Accepted

## Context

Scoped main-isolate CPU sampling and the matching Flutter timeline identify
an entry build of 34.546ms. Of its 27 CPU samples, 21 include
`sourceLogicalChapterOrderKey` and opaque Mihon identity decoding inside the
sort comparator. A 27-chapter reverse catalog invokes the extractor 702 times.
This is separate from loading geometry and native worker ownership.

## Decision

Home projects one logical sequence key per chapter when constructing the
existing invocation-local sort records. The comparator compares integers and
uses source position to preserve ties. Each new invocation consumes current
source keys. Chapter objects and opaque runtime/download identities are kept.

There is no retained catalog cache, changed source ordering, new isolate,
scheduling owner or network gate. Reader/Pipeline ownership and measured
native worker boundaries retain their existing contracts.

## Validation and limits

The failing-first extraction-count contract and 94 focused App tests pass
after the fix, including legacy/fresh Mihon order, stable ties, catalog-model
matching and cold chapter entry. Required gate2163/27 + Rust22 passes. Two
Profile entries change34.546/32.690ms builds to10.263/12.857ms and whole-window
order-key inclusive samples33/31 to1/3. Combined gate2164/27 + Rust22 and
ordinary minified Release revalidation pass. Complete7159/3119-event exports
retain slider, loading-overlap and previous-tail/next-head behavior.
Sampling is statistical and Profile timing is not a direct before/after
comparison with the earlier Release entry peak of 64.893ms. Startup URI
preparation is separately verified in ADR0363. Combined cold Profile
entry18.126ms and Release reentry26.717ms retain remaining catalog/entry cost;
final display presentation remains independent evidence.
See `docs/audits/loading-chapter-plugin-regressions-2026-10-01.json`.
