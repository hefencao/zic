# dev.322 active download bridge fixed-list repair audit

## Evidence
The 2026-08-20 02:50 dev.321 device trace contains 10,000 exported events and 6,463 `taskFailed` events. Every failure is stage `reader-observation-reconcile`, error type `UnsupportedError`, message `Unsupported operation: Cannot remove from a fixed-length list`. The run therefore cannot be used to evaluate whether dev.321 reduced fixed-position jitter.

## Root cause
`PipelineController._bridgeActiveVerticalDownloads()` built `missingDesired` using `toList(growable: false)` and sorted it. When `allowSpeculativeAdvance` was true and a desired speculative identity was missing, the implementation executed `missingDesired.removeAt(0)`. That mutation is illegal for a fixed-length Dart list and aborts the entire reconcile before the new demand plan can be accepted. Repeated viewport observations then repeatedly hit the same exception, explaining the user's large set of unloaded images.

## Repair
dev.322 keeps the dev.321 bridge policy unchanged. The advance branch reads `missingDesired.first`, sets `missingDesiredStart = 1`, and the later fill loop indexes from that offset. No structural mutation of the fixed-length list occurs. Mandatory downloads for every desired decode/upload/current/transition remain unlimited and immediate; far encoded migration remains one new desired identity per committed current page while active.

## Regression boundary
`packages/pipeline/test/browsing_direction_policy_test.dart` now drives a real active vertical `PipelineController` through committed page movement. The test requires all accepts to return normally, the final plan to retain every decode/upload source DownloadId, the download count to remain bounded, and at least one policy decision to report `downloadBridgeDesiredAdvanced=1`. `tool/test_dev322_active_download_bridge_fixed_list_repair.py` additionally rejects reintroduction of `missingDesired.removeAt` and, when the failing trace is present, confirms the 6,463-failure baseline.

## Next device gate
The next run is valid for jitter attribution only when all images load and the analyzer reports `task_failed=0 fixed_list_failures=0`. Then compare direction-flip download churn and reconcile time against the dev.320 valid baseline (`big_5x5=13`, median reconcile 7.455ms).
