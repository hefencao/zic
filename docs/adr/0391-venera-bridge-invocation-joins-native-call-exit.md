# Venera bridge invocation joins native call exit

Status: Accepted

## Context

Rejecting a request-scoped JavaScript network waiter lets the source promise
unwind promptly. Its `ZicNative.finished` notification can precede the exit of
the native executor work that owns the resolver request. Previously the bridge
forwarded that notification immediately and removed its cancellation identity.
The runtime could therefore return its existing invocation permit while an
admitted native call was still running. A late binary result could also register
a token after cancellation. This is a demonstrated lifecycle defect, not a
proven explanation of the reported chapter19/20 loading problem.

## Decision

Keep completion bookkeeping in the existing native bridge. Admit each async
call before submitting it to the existing executor and retire it in the physical
work's `finally` block, including executor rejection. Stage the original source
result until both JavaScript finish and all admitted native calls have exited.
Keep the request cancellation identity through that same boundary; suppress
late results and remove only the cancelled request's native-byte tokens.

The bookkeeping has no executor, network client, queue, retry or priority policy.
NetLane and the existing canonical source gate remain the scheduling authorities.
The canonical context remains one invocation and the isolated image plane keeps
its two-worker capacity. Public source hooks, HTTP and cache authority, locators,
payload revisions, validators, DownloadIds and Reader behavior remain unchanged.

## Consequences and acceptance

Prompt JavaScript unwind is independent of invocation permit retirement. Both
cancelled requests and successful requests that leave unawaited native work
must join that work. Repeated finish/late replies must not return a permit twice.
Bridge teardown closes admission and retains native-call registration until
exit; complete runtime/process-loss and transport cancellation acceptance remain
separate gates. The Venera full-body/transform carrier is still unimplemented.

Blocked physical work, admission-before-executor-start, multiple calls, result
publication, late replies, activation and close bookkeeping require behavioral
tests. Full toolchains, packages and the actual Android bridge must be checked
before treating this scoped prerequisite as verified. See
`docs/audits/venera-bridge-native-call-drain-2026-10-04.json`.
