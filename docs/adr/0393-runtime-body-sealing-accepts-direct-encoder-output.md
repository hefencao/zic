# Runtime body sealing accepts direct encoder output

Status: Accepted

## Context

The Venera transform path still collects full host input and returns full output
arrays. Its existing transient body file owner accepts only an InputStream.
A native bitmap encoder produces through an OutputStream, so connecting it to
that owner otherwise requires a complete intermediate array or a new pipe.
This is a missing carrier primitive, not a proven cause of the reported
chapter19/20 intermittent loading issue.

## Decision

Add a synchronous producer callback to the existing RuntimeServicePacketFiles
body transaction. The InputStream entrypoint delegates to that transaction.
The callback borrows a bounded stream. The owner closes it before sealing and
computes the same length, SHA-256, legacy FNV and64-byte prefix during writes.
Any write, flush, limit or cancellation failure prevents publication even when
the producer catches the exception. The owner also checks cancellation when
the producer returns. A retained stream cannot mutate a sealed file.

There is no new file owner, pipe, executor, queue, scheduling capacity or retry
policy. The caller retains its existing physical invocation lifetime while the
producer runs. Claim/release, wire metadata and persistent identities stay
unchanged. This primitive does not itself integrate Venera transform bodies.

## Consequences and verification

All108 Android unit checks pass, including five producer contract checks and
the original14 packet/body cases. The old owner lacks the producer capability;
four baseline cases fail for that absence. Its cancellation fixture cannot
enter a missing callback and is not evidence of an old cancellation defect.

Required toolchain2259/Rust22 and all three Profile/Release ABIs pass. The same
device probe observes the missing capability on the old Profile and verifies
a919758-byte native PNG producer on the new Profile: decoder/pixel checks,
exact legacy stream proof, admitted lease survival, retired stream rejection,
caught limit failure and physical producer cancellation all pass. Reflection
cannot use an internal class name in the minified Release; that lookup failure
is a probe limitation rather than a product defect.

Ordinary Release3d835b38 passes six cached19/20 slider/boundary steps. Its5822
events contain122 artifact-cache reads and no download/failure. All120 complete
chapter payloads remain exact; only two progress timestamps change, with their
page and fraction unchanged. Temporary instrumentation is removed and the
device is left on Home with debug tracing preserved.

Acceptance covers the body transaction primitive. Host input collection,
canonical/isolated output integration, real-origin/process-loss/Binder lifetime
and original loading/performance acceptance remain open. Keep canonical
Venera1 and isolated transforms2. No throughput or final-display gain is proven.
