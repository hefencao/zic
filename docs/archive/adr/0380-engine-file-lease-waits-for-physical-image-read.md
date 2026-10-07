# ADR 0380: Engine file lease waits for physical image read

Status: Accepted

## Context

Ordinary Release slider acceptance displays an image-read error for the closed
path `/proc/self/fd/250` below the visible page 78 image. The exported trace has
8256 events and no taskFailed event; that count does not prove presentation.
The exact failed page/descriptor is not recorded in the ordinary trace.

Detached static prewarm races its first-frame Future against token cancellation.
Cancelling the listener does not cancel Flutter FileImage's file-length,
ImmutableBuffer or codec Future. Its finally block previously closed the file
lease immediately. A new mounted consumer can still join the same cache entry's
pending completer. Mounted replacement/disposal similarly released its file
lease while such a read could remain in flight.

A failing-first test holds a real file read at its length check, cancels prewarm
and joins its already-admitted pending completer. The previous code releases
the backing file before the read continues. This proves the lifetime defect;
matching fresh device acceptance is still required for the observed error.

## Decision

The existing storage bridge exposes EncodedFileImageLease. The renderer's
file provider pins this lease over each actual file/buffer/codec Future.
Release withdraws permission to start another read and completes descriptor
close only after all started reads have exited, including failure paths.
Detached prewarm awaits that release completion; mounted teardown requests
release without blocking the Reader route.

Both callers use this capability. Ordinary unleased file providers retain
their existing behavior. The provider retains the existing file/memory-neutral
generation key and viewport resize policy. Raster residency remains with the
single PipelinePresentationRasterCache. No cache, queue, worker, scheduler,
Reader state, resource window or budget is added.

## Validation

The failing-first public prewarm test now passes with a shared pending consumer
receiving its frame and exactly one final release. Existing generation,
resident handoff, late cancellation and storage provider tests must pass.
Final gate2208/Rust22 and three-ABI Profile/Release pass. Ordinary Release
8323-event acceptance verifies five stationary sliders, four direction/endpoints
and zero visible file-read errors in captured XML/screenshots. Independent
build/GC/input/final-display performance remains open.

Evidence: `docs/archive/audits/presentation-file-lease-regression-2026-10-03.json`.
