# Venera resolver network error classification audit — 2026-09-13

## Observation

Reader entered successfully and then the current image immediately reported `Failure(source)` whose nested cause was `venera-resolver-http-failed` / rhttp-hyper TLS I/O (`cannot decrypt peer's message`). The visible error was the page-level “图片无法打开”, not DeferredReaderRoute's “章节加载失败”.

## Timing boundary

`_openImportedChapterLoader()` pushes DeferredReaderRoute first. `_prepareImportedChapter()` loads/hydrates the chapter and creates `LocalImageResponseSource` closures, but does not execute per-page `resolveResource`. After the prepared Reader screen is built, current-page DemandPlan reconciliation starts the physical download; `ExternalPluginResourceTransportPool._resolve()` then invokes Venera `resolveResource`. Therefore an error that appears immediately after Reader becomes visible can still be a post-entry request-plan/network failure.

## Root cause

The rhttp executor already emitted a typed `PlatformException(code: venera-resolver-http-failed)`. `DartRhttpVeneraResolverTransport` flattened that into `IllegalStateException("code: message")`; the async WebView bridge then returned only an `error` string. `__zicInvoke` guessed retryability with a text regex. The TLS text `cannot decrypt peer's message` did not match `timeout|connect|network|dns|temporar|HTTP 5xx`, so the runtime envelope said `retryable=false`; `runtime_source_adapter` consequently mapped it to `ErrorCode.source`.

## Repair

`VeneraResolverHttpException` now carries resolver code and retryability through Kotlin. Bridge failure envelopes preserve `errorCode` and `retryable`; JS reconstructs those fields on the thrown Error, and `__zicInvoke` honors typed retryability before its legacy text heuristic. `venera-resolver-http-failed` therefore becomes the existing runtime `ErrorCode.network` path.

No retry was added to the resolver, WebView bridge, Reader, or presentation. `DownloadTransferOwner` remains the sole physical retry/terminal owner: its provider `RetryPolicy` handles network failures inside the existing attempt loop and does not multiply that budget into owner recovery.

The underlying TLS event is still a genuine transport failure. A single occurrence does not identify whether the peer, an intermediary/proxy, network corruption, or a reused connection caused it; the repair only prevents that transport failure from being falsely classified as a source-semantic terminal error.

## Validation

- `tool/test_venera_bootstrap.py`: actual bootstrap JS preserves typed resolver retryability through the final Venera operation envelope.
- Android `VeneraNetworkPolicyTest`: typed resolver HTTP failures retain `errorCode/retryable`, while generic source failures do not gain network retryability.
- `plugin_host/test/runtime_source_adapter_test.dart`: 31/31.
- `downloads/test/source_resource_transport_test.dart`: 24/24.
- Reader transfer progress focused widget tests: 5/5; unknown-total activity stays indeterminate and is now 1.5px high.
