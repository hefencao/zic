# ADR 0349: Mihon catalog exclusion and physical invocation retirement

Status: Accepted

## Context

Metadata refresh and chapter resolution can concurrently invoke getMangaUpdate for the same manga. The source rejects this overlap. FutureTask.done also runs immediately at cancel, while an active Callable or suspend continuation can still be running.

## Decision

Runtime catalog operations use cancellable, reference-counted exclusion keyed by source and canonical manga URL. Exclusion stays inside already-admitted operations and does not choose network admission or priority. Other manga remain independent; existing source chapter objects and capability-only legacy fallbacks are preserved.

Runtime completion and close cleanup follow actual Callable retirement. A cancelled task that never started retires immediately. EmptyCoroutineContext cannot cancel a suspend source operation, so its adapter drains the actual continuation before releasing exclusion or completion, then preserves interruption for request cancellation.

## Consequences

NetLane remains the scheduling authority, with no global FIFO or UI gate. Executable production-code harnesses verify same-manga exclusion, independent manga progress, cancellable waiting, error cleanup, active cancellation drainage and never-started cancellation. Android build and device metadata refresh remain required verification.

## Verification

The Kotlin behavior harness and final three-ABI Android debug/Profile builds pass. Five metadata refreshes complete in the 14-55-08 device boundary sequence with no static-chapter task failure; cancellation fault cases are covered by the executable harness. Evidence: [chapter-boundary audit](../audits/chapter-boundary-trace-regressions-2026-09-30.json).
