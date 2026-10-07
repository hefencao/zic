# dev.254 验证结果

## 基线与输入
- 唯一代码基线：`zic_v0.31.0-dev.253_logical-source-watch-generation-binding.zip`。
- 真机输入：`zic-debug-trace-2026-08-13T02-27-59.jsonl`。
- 当前候选：Source `0.31.0-dev.254` / App `0.31.0+254`。

## 变更范围
production仅收口两条已证实故障链：DecodeSession删除physical DownloadSession epoch authority并只消费Reader-local ingress generation；LiveCoordinator拒绝静默failed snapshot consumption。consumerPacing从无限pseudo-drain改为100ms bounded dwell后flow suspension，DownloadJob正常pause writer保存partial，TransferOwner按当前frame target保持quiescent partial直到credit变化。3/7、5/3/2/1、NetLane 5+1、provider/partial/progress不变。

## 可执行验证
- dev.205–dev.254历史/ownership gate：**50/50 PASS**，`max_workers=8`。
- 核心门禁：**10/10 PASS**；Dart structure为361个Dart文件/135个test文件。
- dev.251/dev.252历史flow gate已版本化：dev.254起要求`pseudo-suspended`并禁止production `pseudo-drain`，不恢复旧实现。
- 完整`tool/check.sh`仍只在唯一基线缺失`third_party/source_archives/libwebp-1.6.0.zip`时停止；未从旧包/Library补依赖。
- 当前环境无Dart/Flutter/Cargo，因此不宣称Dart行为测试、Flutter analyze/build或Rust tests实际执行；Kotlin compile boundary实际通过。

## 发行重建验证
- dev.253→dev.254 `git apply --check --index`：PASS。
- `git apply --index`：PASS。
- packaged replay在第三份独立干净dev.253 Git baseline执行：PASS。
- patch reconstructed tree：50/50历史gate + 10/10核心门禁 PASS。
- full ZIP extracted tree：50/50历史gate + 10/10核心门禁 PASS。
- patch/full/replay目标比较：`missing=0 extra=0 content=0 executable-bit=0 type=0`。
