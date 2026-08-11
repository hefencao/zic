# dev.226 validation results

## 变更边界

- 删除 `LiveCoordinator` / `DownloadTransferConsumer` 的 late verified-equivalent takeover 委托；Reader 与 command consumer 不再拥有该补偿。
- composition promotion listener 改为只扫描 `DownloadRegistry.findExact()` 独立 physical session；acquire-time alias 后没有独立 session 的 identity 不再进入 legacy path。
- `DownloadTransferOwner` 保留最后的 independent-exact compatibility takeover，并明确 trace `compatibilityPath=true` / `compatibilityScope=independent-exact-session`。
- 新增 `verified-transfer-acquire-alias` trace，区分 `joined-existing-physical` 与 ambiguous existing owners rejection。
- 保留 physical transfer → `PartialDownloadStore` / `ArtifactCacheManager` persistence，不改变 NetLane、水位、retry、decode/upload/presentation、chapter claim 或 Phase C1 alias 规则。

## 真机输入审计

用户 15:01 Trace 共 4253 条 event。分类结果：

- `downloadStarted=28`、`downloadPreempted=13`；
- `taskFailed=0`、`writerRejected=0`，未发现 `sessionBusy/writerBusy`；
- 25 个 `pageHostDisposed` 均 `firstFrameReady=true`；
- legacy `verified-equivalent-promotion-takeover=0`；
- `session-partial-handoff` 12 次，全部 `stored`；
- `session-artifact-handoff` 48 次，其中 5 `stored`、43 `skip-existing`。

因此本轮只收缩错误 owner / dead delegation；partial/artifact handoff继续作为 composition physical → durable owner 的正常边界。

## 已实际执行

- `tool/check_documentation.py`：PASS。
- `tool/check_dart_structure.py`：PASS（352 Dart files / 131 test files）。
- `tool/check_test_quarantine.py`：PASS。
- `tool/test_reader_streaming_contract.py`：PASS。
- `tool/test_pipeline_demand_stability.py`：PASS。
- `tool/test_ui_architecture_contract.py`：PASS。
- dev.205–dev.226 相关 ownership/version/partial/Reader gates：PASS（并行 8 workers）。
- dev.206 Kotlin facade compile gate：PASS，仅有 stub unused-parameter warning。
- `tool/test_dev226_phase_e_takeover_contraction.py`：PASS。

## 工具链边界

- Dart SDK：不可用。
- Flutter SDK：不可用。
- Java / Kotlin compiler：可用。
- `bash tool/check.sh`：在首个 pinned source archive presence gate 停止，因为唯一 dev.225 基线不含 `third_party/source_archives/libwebp-1.6.0.zip`。未从历史版本、参考实现或独立 archive 补入。
- 因 Dart/Flutter 不可用，本轮新增 Dart 行为回归源码没有实际执行；不得记为 `flutter analyze` / Dart tests / Flutter tests / APK build 通过。

## 发行重放

预冻结 pristine dev.225 ordinary Patch 已实际执行：

- `git apply --check --index`：PASS。
- `git apply --index`：PASS。
- 与冻结候选树比较：`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。

预冻结完整 ZIP 独立解压比较：`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。

预冻结 Exact Replay v1 在第三份 pristine dev.225 Git index 上执行 `git apply --check --index` / `git apply --index` 后：`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。

validation 写回后将重新生成最终 Patch/ZIP/Exact bundle 并再执行同样三路验证；最终外部 validation / Exact Replay 报告以最后一次 freeze 为准。
