# dev.246 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.245_borrow-first-demotion-rank-hysteresis.zip`。
- 真机输入：`zic-debug-trace-2026-08-12T12-15-21.jsonl`。
- 当前候选：Source `0.31.0-dev.246` / App `0.31.0+246`。

## 变更范围

production只收口最终图片NetLane destructive-preemption transaction：dev.245 normal-pressure删除与borrow-first保留；victim-side 200ms demotion grace删除，改为blocked high-priority candidate 100ms稳定窗口；每个lane最多一个scheduler preemption victim尚未物理退出。`NetPolicyRank`/restart-cost曲线、network5+reserved1、DownloadSession partial、provider task lifetime、双进度、DecodeSession与Venera单context gate不变。

## 已执行验证

- dev.205–dev.246 history/ownership gates：42/42 PASS，最多8 workers。
- documentation responsibility：PASS。
- Dart structure：PASS（357 files / 133 test files）。
- Pipeline runtime compile boundary、Pipeline demand stability、Reader streaming、UI architecture、test quarantine：PASS。
- Android runtime dependency mutation check、texture bridge Kotlin compile：PASS。
- dev.139 current-documentation consistency：PASS。
- `bash tool/check.sh`实际执行，仍在第一项因dev.245基线缺失`third_party/source_archives/libwebp-1.6.0.zip`退出；未从历史包或文件库补入。

当前环境无Dart/Flutter/Cargo；有Kotlin compiler。因此不宣称Dart行为测试、`flutter analyze`/build或Rust tests已运行。新增Dart行为回归已写入仓库，需用户本地工具链/真机继续验证。

## 真机待验证

下一Trace重点确认：最终图片`downloadPreempted`仍只来自真正5+1饱和后的current；每次preempt的`incomingWaitMicros>=100000`；快速scrub中100ms内被后续current替换的pending candidate不再cancel连接；一个scheduler-preemption victim尚未物理退出前不得出现第二个preemption victim。
