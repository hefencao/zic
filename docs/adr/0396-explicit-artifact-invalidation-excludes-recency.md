# Explicit artifact invalidation excludes recency

Status: Accepted

## Context

The full repository gate fails the existing remounted Direct-alias test:
after a verified cache read and explicit invalidation, its logical record is
still present. An isolated rerun passes. This is not a physical cleanup timing
assertion: the failure is the surviving indexed record.

Foreground reads submit maintenance touch asynchronously. Invalidation takes
a record snapshot, then checks it again under the original artifact/replica
mutation boundary. The shared comparison includes touchedUs; a background
touch between those reads causes invalidation to return without removing the
same unchanged body. Recency is not body authority.

A deterministic SQLite metadata interleaving reproduces this: touch-only
fails to remove the row, while a replaced createdUs generation is correctly
protected. No fixture expectation or original alias test is weakened.

## Decision

Only the public explicit invalidateArtifact command compares authority without
recency, both before and after taking the existing physical mutation boundary.
Keep identity, state, locator, byte length, checksum/algorithm, creation epoch,
pin and artifact/root authority comparisons. All other uses retain the full
record comparison, including recency: trim, maintenance eviction, adoption,
internal read checks and their snapshot protection are unchanged.

Keep deferred touch on the original StorageWriteScheduler and SQLite worker.
Do not serialize it with foreground work, add a lock/owner/retry or restore
synchronous presentation touch. Cache identity, trust, network and Reader
resource policies are unchanged.

## Verification and limits

The valid touch-only failing-first and replacement-protection evidence are in
`docs/audits/explicit-artifact-invalidation-recency-2026-10-04.json`.
The full gate passes2280 Dart/Flutter tests,27 suites/analyzers and22 Rust
tests;108 Android tests and all-three-ABI Profile/minified Release packages
pass. Ordinary Release performs one explicit reload with one intentional
download, displays its218446-byte sealed runtime body at1s/6s, then serves11
cached pages with no download/failure after an actual force-stop/relaunch.
The device command verifies reload/reuse; the controlled SQLite test alone
forces the touch interleaving. It does not claim the device reproduced that
exact race. All120 chapter payloads remain exact in strict export comparison.
This defect is independent of
ADR0395's geometry drift and is not evidence that the original intermittent
chapter19/20 loading cause has been identified.
