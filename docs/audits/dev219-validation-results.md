# dev.219 验证结果

目标版本：`0.31.0-dev.219` / App `0.31.0+219`

## 当前环境可执行

- 文档责任/结构检查。
- dev.214–219 ownership静态门禁及适用历史Reader/prefetch门禁。
- Python/static repository检查。
- dev.206 Kotlin facade stub compile（环境存在 kotlinc）。

## 新增行为覆盖（源码已实现）

- physical DownloadSession 已有 committed prefix 时，Reader-local ingress registry 的 `get()` 不抛错；projection先返回，随后 synchronized replay，最终 sourceReady，并可独立detach。另新增LiveCoordinator级回归：已有promoted physical session的late Reader仍须在同一次DemandPlan建立decode/upload，并在projection settled后产出upload。
- observation seam使用 enqueue/latest-wins microtask，不从 Reader callback同步执行 pipeline reconcile。
- DecodeTarget变化只更新既有PipelineController target；下一条enqueue observation从当前DemandPlan增量重算。新增pipeline回归要求download diff为空、decode/upload identity按新raster替换；ReaderController/requested page保持同一owner。

当前环境无 Dart/Flutter SDK，因此不得声称上述 Dart/Flutter tests、`flutter analyze`或APK build实际通过。完整 `tool/check.sh` 若仍在基线缺失的 pinned `third_party/source_archives/libwebp-1.6.0.zip`处停止，应记录为既有环境/基线限制，不得从旧包偷补。
