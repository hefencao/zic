# dev.223 Validation Results

## 范围

验证dev.222真机scrub边界后继续完成composition physical ownership迁移：public `CompositionDownloadTransferRuntime`提升到downloads/App owner，Reader/prefetch/chapter command共享exact `DownloadId` physical transfer；durable store、chapter command与composition lifecycle拆开；priority与required completion拆开；resident immutability与durable body authority拆开。

## dev.222真机输入

`zic-debug-trace-2026-08-11T12-28-34.jsonl`共7,529 events；219个policyDecision中132个为`interaction=scrubbing`，132/132全部严格为1 download / 1 decode / 1 upload。decodeState为decoding=166、waitingSource=154、ready=143、idle=132、failed=0；未见sessionBusy/writerBusy。123个pageHostDisposed中92个未出首帧，但最长约1.853s，属于快速scrub中间host，不再出现此前6–9s resident late-join长黑页。因此本轮冻结Reader scrub、late projection和NetLane参数，转向chapter/whole physical owner迁移。

## 源码/结构验证

已实际通过：

- `tool/check_documentation.py`；
- `tool/check_dart_structure.py`：352 Dart files / 131 test files；
- `tool/check_test_quarantine.py`、UI architecture、Reader streaming、pipeline demand stability；
- dev.113、115、118、174–192、195–223中本轮适用的ownership/preemption/partial/version/Reader边界 gates；
- dev.206 Kotlin facade stub实际编译，仅有stub未使用参数warning；
- dev.223 gate确认chapter command区域没有source/network `DownloadRegistry/DownloadJob/NetLane`，whole-comic仅聚合chapter command，Reader与chapter都attach public composition runtime；
- 透明`ByteResponse` wrapper逐处审计：凡透传`response.disposition`者均同步透传`response.bodyAuthority`；生产代码不再以`residentCacheBacked`判断cache ownership，该名字只保留兼容getter。

新增Dart行为回归源码覆盖：Reader-like + chapter同exact id仅一次physical transport；chapter cancel只撤销自己的claim；checksum冲突原子拒绝；required completion可完成低priority costly full-body catch-up；source-resident local immutable physical session可保持session artifact为0，但显式chapter completion必须经composition resident replay materialize并在exact durable store可读。当前环境无Dart/Flutter SDK，因此不声称这些Dart tests、`flutter analyze`或APK build已实际执行。

## 工具链限制

- Dart/Flutter：不可用；cargo：不可用。
- Java/Kotlin、cmake、ninja、node、git、zip/unzip：可用。
- `bash tool/check.sh`实际执行后仍在第一步停止：baseline缺少`third_party/source_archives/libwebp-1.6.0.zip`。未从历史包或独立reference偷补，因此不声称full check通过。

## 发行与Exact Patch Replay验证

最终release patch从全新dev.222 Git index到冻结dev.223目标提交生成。随后在第二份全新dev.222工作树实际执行`git apply --check --index`与`git apply --index`，与冻结目标逐文件比较：missing=0、extra=0、content=0、executable-bit=0、type=0。完整项目ZIP在独立目录用权限保持解压后得到相同五项0差异，禁止发行项为0。Exact Patch Replay v1携带同一最终patch与冻结target manifest，并在第三份全新dev.222 Git index上自测通过，同样得到五项0差异。

`bash tool/check.sh`最终复跑仍只在唯一基线缺少pinned `third_party/source_archives/libwebp-1.6.0.zip`处停止；没有从旧版本、参考实现或独立归档补入。
