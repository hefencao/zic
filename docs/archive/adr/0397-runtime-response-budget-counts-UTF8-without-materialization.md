# Runtime response budget counts UTF-8 without materialization

Status: Accepted

## Context

The current ordinary Profile allocation capture observes 2692 distinct
Uint8List allocations with `_wireSize` on the main UI thread during actual
chapter boundary operations. The existing response-size check fully encodes
each string key and value only to obtain its byte length. The recursive
inclusive count of 9108 is not a count of distinct allocations.

The size check is a security and resource contract used by `_invokeMeasured`.
It must run even when diagnostics are disabled and must not trust a backend
size declaration or become a separate scheduling or cache authority.

## Decision

Count string UTF-8 bytes directly from UTF-16 code units in the same adapter.
ASCII uses one byte, two-byte scalars use two, BMP scalars use three, valid
surrogate pairs use four and each unpaired surrogate uses the existing
encoder's three-byte U+FFFD replacement. Count map keys with the same helper.
Keep the response limit, recursion/type checks, scalar/binary counting,
body-file rejection cleanup and invocation cancellation/gates unchanged.

No worker, cache, locator, trust, Reader/Pipeline policy or owner is added.

## Verification and limits

Nine actual adapter tests compare exact-limit acceptance and one-byte-over
rejection with the existing encoder for ASCII, scalar boundaries, emoji and
unpaired/mixed surrogates. They pass before and after the edit: the defect
evidence is the real allocation capture, not a failing semantic test.
All2289 Dart/Flutter tests,27 suites/analyzers,22 Rust and108 Android tests
pass. All three ordinary Profile/minified Release ABIs match source inputs
and unchanged native media. The new ordinary Profile repeats the real
boundary actions: `_wireSize` Uint8List allocations are zero, while23
allocation samples and2 CPU samples still establish the runtime invocation
path. Total traced allocations rise from23094 to24348, so no total-allocation
or overall-performance reduction is claimed. Profiling flags and task-owned
ADB forwarding are restored, then the ordinary Release is installed.

The new Release passes six stationary slider/edge steps and three independent
saved-history cases:204 artifact reads with no download/failure. One explicit
reload makes one intentional218446-byte origin download and displays the
page at1s/6s; an actual force-stop/relaunch then makes11 cache reads with no
download/failure and preserves page4. All120 complete chapter payloads and
URI/revision fields stay exact, with only actual reading state and export
time changes. Evidence and scoped acceptance are recorded in
`docs/archive/audits/runtime-response-UTF8-allocation-2026-10-05.json`.
This scope does not identify or close the original intermittent chapter19/20
loading cause, GC/input latency or final physical presentation acceptance.
