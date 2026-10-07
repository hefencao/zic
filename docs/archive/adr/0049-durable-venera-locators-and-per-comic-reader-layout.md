# ADR 0049: Durable Venera locators and per-comic Reader layout

Status: Accepted in `0.31.0-dev.65`; Venera locator recovery details are superseded in part by ADR 0050.

## Context

Venera chapter manifests used `venera-resource://<token>` values backed by a JavaScript `Map` inside one WebView runtime generation. Catalog and Reader records outlived that generation, so later pages could still reference tokens after the map had disappeared. The Reader also exposed only global defaults; vertical mode remained a vertical `PageView`, and the page slider did not mirror RTL navigation. Trace producers could synchronously notify the diagnostics projection while a Reader page was building.

VibeVenera demonstrates a useful product shape for adaptive reading: a global opt-in, a per-comic override, a persisted profile and a confidence gate. ZIC must retain its existing ownership boundaries and cannot copy VibeVenera's Reader/resource implementation.

## Decision

- Newly generated Venera page locators use `venera-resource:<base64url-json>`. The versioned payload contains only the original image identity plus comic/episode identity. Decoding rejects other shapes and reconstructs a deferred `onImageLoad` request; it cannot carry arbitrary headers, methods, scripts or final network configuration.
- Legacy `venera-resource://token` values remain readable only while the original runtime generation still retains the token. Persisted legacy records require the dev.66 chapter refresh described by ADR 0050; no new chapter emits them.
- App preferences store a bounded map keyed by `sourceId + comicId`. A record may override direction, vertical stitching and adaptive enablement. It contains no page bytes, plugin state, downloads, cache references or policy commands.
- Adaptive classification uses only existing `ChapterManifest` evidence: source direction, declared animation hints and page geometry. A result applies only above the confidence threshold; otherwise source/progress defaults win. Animation biases toward paged presentation, while a strong tall-page majority selects vertical.
- Vertical presentation uses a proportional continuous list. Each page retains its own stable page/asset/artifact identity. Stitching changes only the visual separator height.
- RTL wraps the slider in RTL `Directionality` and mirrors endpoint labels. Domain page indices and stored progress remain zero-based and unchanged.
- `DebugTraceLog` mutates its bounded event list immediately but coalesces observer notifications to the next frame.

## Consequences

Later Venera pages can be re-resolved after runtime recreation without retaining a WebView generation indefinitely. Per-comic reading behavior is durable and user-controlled without introducing a second Reader policy owner. Continuous reading and RTL controls match their visible navigation semantics. Diagnostics remain observable without violating Flutter's build-phase notification rules.
