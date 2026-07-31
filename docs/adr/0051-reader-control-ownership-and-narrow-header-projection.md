# ADR 0051: Reader control ownership and narrow header projection

Status: Accepted in `0.31.0-dev.67`.

## Context

`ReaderRuntimeScreen` exposed arbitrary title and action Widget builders. The local-folder Reader used those hooks to add a second page counter, previous/next buttons and a page menu, while runtime also exposed a top layout menu. The bottom Slider, direct gestures and per-comic settings already owned the same behavior. This produced duplicate state paths, increased test surface and allowed source-specific presentation to hold `ReaderController`.

The same runtime file also contained session settings and adaptive classification models alongside transport composition and Widget code.

## Decision

- Bottom Slider and direct Reader gestures are the only page-navigation surface.
- Global and per-comic settings are the only layout-selection surface.
- The top bar contains back, chapter title, optional plain-text page subtitle, transfer progress and per-comic settings only.
- Remove arbitrary action/title Widget builders. Callers may provide only `pageSubtitleBuilder(PageAsset) -> String`.
- Local-media UI must not call `ReaderController.requestPage` or retain separate previous/next/menu state.
- Move session settings and adaptive classification to `reader_session_settings.dart` and enforce a 1500-line budget for the runtime screen.
- A vertical page command is acknowledged only after the target child is laid out and the resulting viewport observation is published.

## Consequences

Source-specific Readers cannot add one-off navigation controls without changing the shared Reader contract. Tests target one navigation path and stable semantic keys. The runtime screen has fewer extension points and fewer responsibilities. A future page thumbnail scrubber or chapter navigator must replace or extend the canonical bottom control surface rather than coexist as another owner.
