# dev.65–dev.68 Venera / continuous Reader regression audit

## Scope

This audit compares the delivered dev.65, dev.66, dev.67 and dev.68 source trees against the device trace and the repeatedly failing vertical Widget test. It records what actually changed, not what release notes claimed.

## Findings

| Version | Change that actually landed | Missing closure / regression |
| --- | --- | --- |
| dev.65 | Introduced durable Venera locator payloads and proportional vertical `ListView`. | The global resource resolver referenced a source outside its scope; ordinary image bytes still returned through JS/Base64. The new vertical test immediately queried lazy page/separator widgets with `tester.widget`, creating the persistent `Bad state: No element` failure. |
| dev.66 | Passed source explicitly, refreshed legacy locator generations, and added measured media geometry. | Geometry updates called current-page synchronization and could recenter scrolling; resource bytes still crossed JS/Base64. Only the second-page lookup was partially changed; the earlier separator lookup remained unsafe. |
| dev.67 | Removed redundant top controls and narrowed Reader composition APIs. | The dev.65 lazy separator lookup was left unchanged, while no device-level Venera byte-path closure was added. |
| dev.68 | Forced old-locator preflight and reduced Venera demand to current plus next. | The dev.65 separator lookup still remained. Native cancellation only ignored results, so detached HTTP work continued. Unchanged role windows still emitted new plans. Large image bytes still crossed JS/Base64. |

## Trace evidence used for dev.69

- Durable locators are present, so old token migration is no longer the principal failure.
- Current page 161 is submitted at revisions 1, 2 and 3 with unchanged page identity.
- Page/demand teardown occurs before the resource calls later report timeout.
- Both current and next pages are active under the dev.68 two-page window.

## dev.69 closure

- Native binary response token for ordinary images.
- Request-scoped native connection cancellation.
- Current-page-only, serialized Venera resource work.
- Pipeline same-role suppression.
- Tri-state stitch migration and no-separator overlap.
- Viewport anchor preservation without jumps during scroll.
- Viewport-level single loading indicator.
- Actual lazy separator test lookup fixed.
