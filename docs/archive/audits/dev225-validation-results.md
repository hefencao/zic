# dev.225 Validation Results

## 范围

本轮只实现 Phase C1：直接 verified equivalence 在 physical acquire 之前允许新的 exact demand 加入一个已经存在且具有物理状态的等价 transfer。`DownloadId` 继续是 Reader/decode/cache/offline 的 exact identity；physical alias 仅存在于 composition runtime / DownloadRegistry 内。

明确不包含：两个已存在 session 的事后 merge、source-resident 且非 ArtifactCacheManager-owned body 的跨版本 join、transitive canonical equivalence union、cold durable partial 的 TransferKey 统一、dev.205–213 late takeover/handoff 兼容路径删除。

## 所有权与行为检查

已验证：

- physical alias 只能在 exact session 创建前绑定到已存在 physical session；
- 查询/诊断 API 不会触发 resolver 或改变 alias；
- Reader `DownloadDemand` 在边界投影为 transfer demand，claim 保留 exact provider identity；
- network/source bucket 使用当前 provider exact URI，而不是 physical anchor URI；
- chapter command 先提交 claim/acquire，再取得 physical session，避免提前创建 exact session 绕过 resolver；
- chapter exact durable completion 在共享 physical transfer 后仍 materialize 自己的 exact durable artifact；
- 两个已经分别存在的 physical session 不事后 merge；
- source-resident、非 ArtifactCacheManager-owned immutable body 不跨版本 join；
- acquire-time alias 证明被冻结在 runtime alias 中，不依赖之后 equivalence LRU 是否仍保留该边；
- decode/upload/presentation identity 未被 physical alias 全局化。

## 实际执行的检查

通过：

- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`（352 Dart files / 131 test files）
- `python3 tool/check_test_quarantine.py`
- `python3 tool/test_ui_architecture_contract.py`
- `python3 tool/test_reader_streaming_contract.py`
- `python3 tool/test_pipeline_demand_stability.py`
- dev.205–dev.225 与本轮相关的 ownership / partial / Reader boundary gates；其中 dev.206 Kotlin facade stub 实际编译通过
- `python3 tool/test_dev225_verified_transfer_alias_before_acquire.py`
- `git diff --check`（发行冻结时再次执行）

## 工具链限制

当前环境无 Dart SDK、Flutter SDK、Cargo；Java/Kotlin、CMake、Ninja 可用。因此本轮新增 Dart 行为测试已写入源码，但未声称实际执行；未声称 `flutter analyze`、Flutter tests、APK build 或设备验证通过。

完整 `bash tool/check.sh` 实际执行后仍在唯一 dev.224 基线缺失的 `third_party/source_archives/libwebp-1.6.0.zip` presence check 处停止。未从旧版本、参考实现或独立 archive 补入该文件。

## 发行重放

预冻结 ordinary Patch replay 已在全新 dev.224 Git index 上实际验证：`git apply --check --index` / `git apply --index` 均通过，且 missing=0、extra=0、content=0、executable-bit=0、type=0。最终冻结后再次对 ordinary Patch、完整 ZIP 和 Exact Replay 独立验证，结果记录在发行 validation / exact-replay 报告中。
