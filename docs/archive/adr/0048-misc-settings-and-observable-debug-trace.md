# ADR 0048: Misc navigation, settings ownership, and observable debug trace

Status: Accepted in `0.31.0-dev.64`.

## Context

The Android information architecture had three root destinations. Product requirements add a fourth `杂项` destination containing quick settings, the complete settings hierarchy, About, and Debug trace. Existing application preferences were implicit widget state, the app theme was hard-coded, and startup traces were printed without a bounded in-app projection.

Settings must not become a new owner of network connections, plugin storage, Reader resources, cache files, or download artifacts. `apps/app` is also forbidden from opening files directly; durable reads and writes must remain behind `storage_bridge`.

## Decision

- The root `NavigationBar` has four destinations: Home, Bookshelf, Comic Sources, and Misc.
- `MiscPage` owns only navigation and observable controls. It exposes quick theme, Reader immersive, and trace-capture choices plus Settings, About, Debug trace, download-manager, and import entries.
- `AppPreferencesController` is a small application read model. Persistence is injected as map read/write functions by composition; the controller imports neither `dart:io` nor storage implementation types. A user mutation that occurs while the durable read is pending wins and is persisted instead of being overwritten by stale startup data.
- Theme mode rebuilds `MaterialApp`. Bookshelf defaults update the existing shelf projection. Default Reader mode and immersive behavior are passed into the existing Reader composition and do not create a second Reader policy.
- Whole-comic network, power, and concurrency settings call the existing persistent `WholeComicDownloadQueue.updatePolicy`; Settings does not create a scheduler.
- Data backup reads the catalog store contract and exports metadata only. Cache inspect/clear calls `ResourceCacheCoordinator`, preserving response-cache and artifact ownership.
- `DebugTraceLog` is a bounded `TraceSink` projection. Producers keep their existing trace ownership; the UI may observe, copy, clear, or disable capture but cannot control pipeline decisions. Late startup events after UI disposal are ignored safely.

## Consequences

The fourth destination can grow without returning diagnostic and settings controls to Home. App preferences remain durable without violating the app-layer file-I/O gate. Reader, download, cache, plugin, and network ownership remain unchanged. Trace memory is bounded to the most recent 500 events by default.
