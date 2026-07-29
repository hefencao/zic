# ADR 0030: Single image-stream ownership, authoritative artifact priming and raw plugin runtime channels

## Status

Accepted.

## Context

A local static image was rendered by Flutter's `Image` widget while `LocalImagePlayer` separately called `ImageProvider.resolve` to infer readiness. That created two listeners and two lifecycles for one file-backed provider. In widget tests, platform image decoding can complete outside the fake timer queue; after earlier animated codec failures, the duplicate stream and retained codec/timer work made the later plain-file test appear to block and complicated suite shutdown.

Cold Reader media had a related ownership timing gap. Page media joined a promoted-artifact read, but the read was not guaranteed to start until the replacement session reached a later queued/receiving state. Ephemeral workspace restoration could therefore delay the cache hit even though `beginRun` had already established the authoritative transport owner.

The external plugin protocol and source adapter existed only as in-process Dart interfaces. A concrete Mihon process or Venera sandbox still needed a narrow raw transport boundary that proves every request and response is serializable and validates startup/source identity before catalog calls.

## Decision

1. A static encoded image has exactly one engine-facing `ImageStream` owner: the Flutter `Image` widget. `LocalImagePlayer` does not manually resolve the same provider. Actual frame delivery through `frameBuilder` publishes ready. Tests for file routing assert `FileImage` and absence of Dart byte loading, then explicitly unmount; decoder completion is tested separately.
2. Tests that depend on host codec or file-provider work yield the real event queue without a guessed duration and explicitly dispose mounted players/providers. Product readiness remains tied to actual presentation, not to a test shortcut.
3. `DownloadSession.beginRun` is the earliest signal that may prime the exact promoted-artifact read. Pages remain join-only. The pool observes the current snapshot immediately, so attachment after `beginRun` cannot miss the transition.
4. Isolated external runtimes expose `ExternalPluginRuntimeMessageChannel`. Startup uses a schema-versioned handshake with a non-empty runtime ID and unique source IDs. Every invocation serializes protocol v1, parses the raw response and matches its request ID. Closing is joinable and rejects new calls.

## Consequences

- Static local files avoid a duplicate provider resolution and keep the zero-Dart-copy path.
- Widget tests no longer use platform decoder completion as proof of file routing and do not leave animation work mounted for subsequent tests.
- A cold promoted page can be read while the new session restores its temporary artifact workspace, without granting the page independent cache authority.
- Mihon and Venera backends can use different process/isolate transports while sharing one audited wire contract. Reader, download-session and artifact objects cannot leak across that boundary.
- Concrete APK class loading and JavaScript evaluation are still separate isolated backends and are not implied by this ADR.
