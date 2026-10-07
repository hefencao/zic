# ADR 0400: Isolated Venera output encoding leaves JavaBridge

Status: Accepted

## Context

Separate image-only WebViews own separate Bitmap namespaces but can share one
JavascriptInterface thread. `TransformBridge.complete` synchronously encoded
PNG on that thread. A controlled actual Android case preflights both workers,
holds one output encoder and proves that another worker cannot finish. Live JM
request-plan waits and thread CPU evidence are recorded independently in the
callback audit; they do not establish the exact PNG share or all waiting causes.

## Decision

Only isolated output encoding borrows the native host's existing executor.
Original transform admission stays bounded at two workers; the canonical source
WebView remains one invocation. No executor pool, FIFO or network gate is added.

The original bridge work drain registers encoding before submission and retires
it after execution. A JS completion callback resumes the existing transform
Promise only after encoding exits. JS then disposes its Bitmap namespace and
calls `finished`; the original pending result and capacity owner remain intact.
Failure and rejected executor submission use that same completion path.

Cancellation does not return capacity while encoding is live. Close seals
admission, joins accepted encoding and only then recycles Bitmaps and retires
pending replies. Late file tokens use the existing body discard callback.
The transform runtime never shuts down the borrowed executor; host retirement
continues to wait for the driver lifetime before executor shutdown.

## Consequences

PNG bytes and negotiated file output retain their existing protocol and owners.
Identity, locator, cache/trust policy, source qualification, source retry,
Reader/Pipeline ownership, NetLane and waterlines remain unchanged.
Image primitive CPU can still occupy JavaBridge, and PNG CPU cost remains real.
Controlled callback/lifetime verification and ordinary real-origin observation
are separate from total performance and the original intermittent loading issue.

Evidence: `docs/audits/venera-isolated-encoding-callback-2026-10-05.json`.

Six actual Android callback/lifetime cases, eleven real Binder body cases,
fresh repository/toolchain checks and ordinary real-origin Release observation
verify this execution boundary. Broader performance remains outside acceptance.
