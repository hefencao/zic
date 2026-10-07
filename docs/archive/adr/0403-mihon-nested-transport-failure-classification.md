# ADR 0403: Mihon nested transport failure classification

Status: Accepted

## Context

A real Roumanwu catalog invocation returned `ConnectException` caused by Android
`ErrnoException` after resolving the configured host to loopback. The driver
classified only the deepest cause, so the non-IO syscall exception erased the
transport failure and the adapter reported `Failure(source)`.

For runtime-owned media, that same mistake could grant source request-plan
replay eligibility to an ordinary connection failure. No evidence establishes
this as the cause of the original chapter 19/20 intermittent loading.

The canonical default client's interceptor also wraps source/parser exceptions
in `IOException`. Treating every outer IO wrapper as a network error would
create a different regression and suppress legitimate source recovery.

## Decision

The existing Mihon host classifier examines the original exception chain. A
concrete socket/connection, DNS, protocol, interrupted-read, EOF or TLS exception
retains network classification despite deeper platform causes. Generic IO/HTTP
classification otherwise follows the existing deepest-cause policy, preserving
source/parser wrapper behavior. Unsupported service/protocol remains a source
error. Cancellation and verification retain their existing precedence.

This changes no retry count, scheduler, source identity, carrier, cache authority
or Reader/Pipeline ownership. The same decision still determines the runtime
retryable flag and exclusion from source resource-plan replay.

## Validation

The production-extracted invocation decision fails before the change for nested
connection refusal and passes after it. Parser IO wrappers, unsupported service
and concrete transport errors with non-IO causes remain covered. A fresh
isolated invocation of the same extension reports the nested connection refusal
as `Failure(network)` and closes the runtime. The resolved address changed
between observations; this proves classification, not equivalent network paths
or successful chapter generation. Fresh2320 Dart/Flutter tests,27 analyzers,
Rust22, Android108 and six ordinary Profile/Release APKs pass. Evidence is in
`docs/archive/audits/mihon-nested-transport-failure-2026-10-07.json`.
