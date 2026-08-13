# dev.257 验证结果

## 基线与输入

- 唯一基线：`zic_v0.31.0-dev.256_monotonic-physical-flow-frame-proof.zip`。
- 真机输入：`zic-debug-trace-2026-08-13T04-58-26.jsonl`，3011条事件。
- 候选：Source `0.31.0-dev.257` / App `0.31.0+257`。

## Trace结论

- preempt/cancelled/download failure均为0；dev.256 frame-prefix proof没有重复正target reopen。
- 31次`downloadStarted`中有3次发生于local prepare已恢复完整promoted artifact之后，三者随后没有真实source/network消费；本轮只收掉该local-completion/provider-admission耦合。

## Production边界

- `DownloadJob.completeWithoutTransport`统一promoted/完整partial的无transport完成。
- TransferOwner在prepare后先short-circuit；只有仍未完成时才lookup provider transport、创建provider lease并记录`downloadStarted`。
- prepare后重新解析当前preferred claim/provider。
- 3/7、5/3/2/1、frame-prefix proof、NetLane、partial/source/decode不变。

## Worktree验证

- dev.205–dev.257历史/ownership gates：53/53 PASS，`max_workers=8`。
- 核心门禁：10/10 PASS。
- Dart structure：361 files / 135 test files。
- documentation responsibility、Pipeline runtime compile boundary、Pipeline demand stability、Reader streaming、UI architecture、test quarantine、Android dependency、Kotlin texture bridge compile、dev.139 current-doc consistency均PASS。

## 完整入口与工具链

- `./tool/check.sh`执行并仅在原dev.256基线缺少`third_party/source_archives/libwebp-1.6.0.zip`处停止；未从旧包或文件库补入。
- `kotlinc`可用；Dart / Flutter / Cargo不可用，因此不得宣称Dart behavior tests、Flutter analyze/build或Rust tests已执行。

## 发行验证

- 候选patch reconstructed tree：dev.205–dev.257 53/53 PASS（`max_workers=8`）+ 核心10/10 PASS。
- 候选full ZIP extracted tree：dev.205–dev.257 53/53 PASS（`max_workers=8`）+ 核心10/10 PASS。
- `git apply --check --index` / `git apply --index`：独立干净dev.256 baseline真实执行PASS。
- packaged `replay.py`：第三份独立dev.256 Git baseline真实执行PASS。
- patch/full/replay target exact compare：`missing=0 extra=0 content=0 executable-bit=0 type=0`。
- staged patch真实变更路径：16。
- 合并执行patch/full候选门禁时在patch树完成后触发总命令timeout；该timeout未计PASS，full ZIP tree随后单独重跑并明确完成53/53+10/10。
- 写入本节后必须从原dev.256重新构建最终patch/full/replay，并对最终发行树重复同等级门禁。
