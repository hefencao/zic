# ADR 0350: Reader retention uses physical media retirement

Status: Accepted

## Context

An animated Reader's exit in the 14-55-08 device ring cancels an active decode, then Pipeline retention directly evicts its cursor before the worker returns. The asynchronous tail reports a decode failure after the Reader is retained. Coordinator already has an exact lane/source retirement barrier, but this direct eviction bypasses it.

## Decision

Pipeline asks the existing Coordinator to retire detached media. Idle upload/decode instances retire immediately. Active instances retain their concrete cursor/source until the existing DecodeLane/UploadLane receipt confirms real exit. Retained static outputs lose their demand-free claim before the same source retirement check. Live demand and source-generation checks continue to prevent old retirement from touching renewed demand.

## Consequences

No new retirement owner, queue, timer, retry or scheduler is introduced. Cancelled workers retain capacity until real exit, and the idle retained session releases its native working set without waiting for TTL. A blocked-decode regression fails before the fix and checks both pre-exit lifetime and automatic post-exit cleanup without disposing the retained session.

## Verification

Media ownership35/35 and final required-toolchain checks pass. The complete 15-50-39 Profile trace retains the active cursor at exit, then reuses the same session after 2.269s with decode/upload counts zero; reentry decodes89/presents40 frames without failure. Evidence: [chapter-boundary audit](../audits/chapter-boundary-trace-regressions-2026-09-30.json).
