# ADR 0015: Durable whole-comic download queue

- Status: accepted
- Version: `0.28.0-dev.32`

## Context

The first whole-comic action lived inside a details route and sequentially invoked chapter downloads. Closing the
route or restarting the process lost scheduling intent, and there was no global concurrency or network/power gate.
Moving byte ownership into a new whole-comic downloader would duplicate the existing DownloadSession/artifact
state machine.

## Decision

Introduce `WholeComicDownloadQueue` as a durable application scheduler. It persists exact source-composite comic
identity, chapter records, completed chapter identities, queue phase, failure and policy. It delegates each chapter
to `ChapterDownloadService`; the existing per-page DownloadSession and promoted artifact remain authoritative.

The queue supports global concurrency, pause/resume, cancel/retry and record removal. Restored `running` jobs become
`queued` and every chapter is inspected before scheduling. Policy may require unmetered connectivity or charging.
When a condition becomes false, active chapters are cancelled through the chapter service and the job waits without
deleting partial artifacts.

Add `runtime_bridge` as a narrow Android signal provider. It reports validated connectivity, metered state and
charging over versioned platform channels. It cannot open transports, mutate artifacts or schedule chapters.

## Consequences

- Whole-comic intent survives route disposal and process restart.
- Chapter and artifact ownership is not duplicated.
- Multiple comics share one explicit concurrency budget.
- Android policy uses real system signals; other hosts require an explicit environment adapter or use the declared
  fallback.
- Source catalog changes are incorporated when a terminal job is enqueued again; an active duplicate request is
  coalesced rather than mutating the live chapter set.
