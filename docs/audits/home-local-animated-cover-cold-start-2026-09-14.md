# Home local animated cover cold-start audit — 2026-09-14

## Scope

This audit follows the Reader local-preparation closeout and rechecks the older report that Home/history covers could take one to several seconds after a cold process start. Measurements use the current profile Dart build with release native media on the same Android device; Android `TotalTime` is recorded only as context, while `homeCoverRequested`, `homeCoverSourceReady`, `homeCoverFirstFrame`, and `homeBootstrapPresented` are the actual artwork observables.

## Fresh baseline

Seven force-stop cold starts were collected before changing Home artwork presentation. Android `TotalTime` was 809–1027 ms. Every visible startup cover came from `durableCacheFile`; no source/plugin/network artwork fetch participated. Six visible retained covers were about 21–61 KiB. One `local-folder` Animated WebP cover was 5,906,374 B.

The historical 1–5 s cover failure no longer reproduced: the last visible cover frame was 231–389 ms after the Home trace epoch, median 367.6 ms and max 389.5 ms. A smaller deterministic tail did remain. In representative runs the six small covers reached first frame around 138–158 ms, while the 5.9 MiB local animated cover reached 355–389 ms. Its retained bytes were already locally available, so this was not startup service handoff, plugin activation, or network latency; it was the cost of materializing and decoding the full animated artwork before Home had any image to show.

## Ownership-preserving change

The final Animated WebP remains the retained `cover` artifact and remains the only final artwork authority. A separate retained `cover-placeholder` key may hold the existing 512×768 static thumbnail derivative. Home starts placeholder and final loads independently. If the placeholder is already cached, `_CoverImage` lets that small source actually paint one visible frame before swapping to an already-ready final source; a late placeholder can never replace a final frame. Placeholder miss or failure is acceleration-only: old records can lazily materialize it in the background, while import/explicit refresh materializes both derivative and final cover at the normal artwork boundary.

This deliberately does not expose response-cache files to `FileImage`, does not copy the whole SAF comic, does not change source/plugin activation, and does not add a new cache owner. `homeCoverSourceReady` now carries diagnostic `presentationStage=placeholder|final` so the two phases can be distinguished without changing policy.

## Device result

After the derivative had been materialized, five fresh profile cold starts produced local placeholder-ready at 41.4–80.7 ms (49,615 B), final original-ready at 122.0–150.7 ms (5,906,374 B), and the local cover first visible frame at 161.8–180.4 ms. The last first-frame across all startup covers is now median 176.8 ms and max 180.4 ms, versus baseline median 367.6 ms and max 389.5 ms. Android `TotalTime` remained in the same broad range, 840–958 ms, which confirms why activity launch time is not a substitute for cover readiness.

The final animated source still replaces the placeholder. After scrolling the Home history row until the `local-folder` card was visible, two screenshots 650 ms apart over only that card had different frame hashes and SSIM 0.609, providing mechanical evidence that the final cover remained animated rather than being permanently replaced by the static derivative.

## Regression evidence

`library_ui_test.dart` includes a two-stage cover regression proving the placeholder can render while the final source Future is unresolved and that telemetry distinguishes placeholder and final readiness. Full `library_ui_test.dart` plus `local_image_preview_test.dart` passed (35 combined tests in the run), the telemetry package passed 13/13, and affected analysis reports no errors or warnings (only existing info-level lints). The profile APK rebuilt successfully and was installed with `adb install -r`; app data was preserved and `low_power=0`.

This closes the current Home cold-cover path. Future cover work should begin from a new visible regression, not from Android `TotalTime` or by bypassing the retained artwork/cache ownership contract.
