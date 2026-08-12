# dev.237 validation results

## Working-tree gates

- dev.205–dev.237 ownership/version/partial gates：33/33 PASS，8 workers。
- documentation responsibility：PASS。
- Dart structure：PASS（354 files / 132 test files）。
- Pipeline runtime compile boundary：PASS。
- Pipeline demand stability：PASS。
- Reader streaming contract：PASS。
- UI architecture contract：PASS。
- test quarantine ownership：PASS。
- Android runtime dependency checks：PASS。
- Android texture bridge Kotlin compile：PASS。

## Full entrypoint

`tool/check.sh`在repository入口被唯一dev.236基线缺失的pinned archive阻断：`third_party/source_archives/libwebp-1.6.0.zip`。未从旧baseline复制该归档。

## Toolchain availability

当前环境无 Dart / Flutter / Cargo；因此新增Dart行为回归、Flutter analyze/App build、Rust tests不声明为已执行。Kotlin可用，targeted texture bridge compile gate已执行。

## Device follow-up

下一份Trace应验证：当retained active provider的claim已orphaned，或另一live claim以严格更高priority成为preferred时，出现`stage=active-provider-handoff/action=cancel-and-rebind`；随后新的`downloadStarted`应使用preferred claim的provider scope/exact URI，同时physical session identity与既有committed prefix保持不变。可见progress仍只在`bytesCommitted`越过旧prefix后增长。
