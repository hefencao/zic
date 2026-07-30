# ADR 0032: Deterministic controlled codec and drain-safe image tests

- Status: Accepted
- Version: 0.31.0-dev.48

## Context

The App test process repeatedly stopped at the plain local-file provider test with Flutter tool stream-channel shutdown errors. Earlier animation assertions had timed out before their explicit cleanup statements, leaving engine codec Futures, image frames and playback timers active. The plain-file test also mounted a real `FileImage` even though its only contract was proving that no full encoded file entered the Dart heap.

`ui.instantiateImageCodec` is an engine boundary and its Future cannot be cancelled by the Dart widget state. Making controlled-animation state-machine tests depend on that external completion made failures contaminate later tests and suite shutdown.

## Decision

1. Extract a minimal `FlutterAnimatedCodec`/`FlutterAnimatedCodecFactory` contract. The production adapter remains `ui.instantiateImageCodec`; tests inject deterministic frame producers.
2. Treat presentation as complete only after `WidgetsBinding.endOfFrame`. Keep the previous frame alive until that boundary and release it when the generation is invalidated.
3. Expose local direct-file provider selection as a pure function. Test zero-Dart-copy routing without mounting an `Image` or starting platform decoding.
4. Put async-media widget cleanup in `finally`, including failed assertions. Teardown removes the widget, cancels timers/tokens, disposes codecs/images and yields the real event loop.
5. Poll external async work against a wall-clock deadline rather than assuming a fixed number of zero-duration pumps proves completion.

## Consequences

- Product playback still uses the real Flutter codec by default.
- State-machine regressions no longer depend on host codec scheduling and can finish deterministically.
- The file-provider test proves routing and ownership only; Flutter's own `FileImage` decoder is not redundantly integration-tested by this unit.
- A failed animation assertion cannot leave long-lived media work attached to the next test.
