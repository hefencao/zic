# dev.256 验证结果

## 基线与输入

- 唯一基线：`zic_v0.31.0-dev.255_scheduler-cancel-partial-lifecycle.zip`。
- 真机输入：`zic-debug-trace-2026-08-13T04-31-24.jsonl`，3353条事件。
- 候选：Source `0.31.0-dev.256` / App `0.31.0+256`。

## Trace结论

- `downloadPreempted=0`、download failed=0、`Failure(cancelled)=0`、`taskFailed/sourceDisabled/decode failed=0`；dev.255 attempt/partial生命周期闭包成立，本轮不再改scheduler。
- `downloadStarted=61`，其中44次为正`flowTargetFrames`；`flow-satisfied=47`。
- 以同identity最近一次`flow-satisfied.completedFrames`和committedLength回放，44次正target start中22次在同一partial上已满足后续target，属于精确target记忆造成的重复open。

## Production边界

- target-specific `_FlowSuspension`改为generation-aware `_FlowFrameProof`；只记录实际`completedFrames`和证明prefix，不保存policy target。
- 任意正target不高于proof且partial未回退时直接quiescent；target=0 foreground unlimited或target高于proof才允许resume。
- proof跨role target变化和短暂无demand保留；physical session generation变化、partial回退、promotion/dispose失效。
- 3/7、5/3/2/1、scrubbing current-only、NetLane 5+1、preemption、partial validity、decode/source/provider均未修改。

## Worktree验证

- dev.205–dev.256历史/ownership gates：52/52 PASS，`max_workers=8`。
- 核心门禁：10/10 PASS。
- Dart structure：361 files / 135 test files。
- documentation responsibility、Pipeline runtime compile boundary、Pipeline demand stability、Reader streaming、UI architecture、test quarantine、Android dependency、Kotlin texture bridge compile、dev.139 current-doc consistency均PASS。

## 完整入口与工具链

- `./tool/check.sh`执行并仅在基线缺少`third_party/source_archives/libwebp-1.6.0.zip`处停止；未从旧包或文件库补入。
- `kotlinc`可用；Dart / Flutter / Cargo不可用，因此不得宣称Dart behavior tests、Flutter analyze/build或Rust tests已执行。

## 发行验证

- 候选patch reconstructed tree：dev.205–dev.256 52/52 PASS（`max_workers=8`）+ 核心10/10 PASS。
- 候选full ZIP extracted tree：dev.205–dev.256 52/52 PASS（`max_workers=8`）+ 核心10/10 PASS。
- `git apply --check --index` / `git apply --index`：独立干净dev.255 baseline真实执行PASS。
- packaged `replay.py`：第三份独立dev.255 Git baseline真实执行PASS。
- patch/full/replay target exact compare：`missing=0 extra=0 content=0 executable-bit=0 type=0`。
- staged patch真实变更路径：16。
- 最终冻结包需在写入本节后由原dev.255重新构建，并重复同等级发行树门禁。
