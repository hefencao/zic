# dev.249 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.248_animated-byte-weighted-prefetch-admission.zip`。
- 真机输入：`zic-debug-trace-2026-08-12T14-13-54(1).jsonl`。
- 当前候选：Source `0.31.0-dev.249` / App `0.31.0+249`。

## Trace结论

Trace共6756事件，`downloadPreempted=13`；normal scrolling/idle阶段动画策略出现46次`downloads=7`，说明dev.247/248已经把3/7的11个网络demand裁成2/4。9次`mediaClassified`均为animated，frameCount主要154并包含173帧；因此主线由“限制哪些页有network资格”改成“3/7页都保留demand，但远端response只读到少量完整ANMF帧”。

## Production变更

- RoleWindow与DownloadDemand均恢复previous3/next7。
- `flowTargetFrames`由Pipeline policy产生并经TransferDemand投影到同一NetLane task；current/可见transition unlimited，next/next2/previous为5/3/2，远端1，既有四级水位把对应外层升到2。
- NetLane删除dev.248 estimated whole-body speculative byte admission；rank、normal5+current reserved1、dev.246 destructive-preemption保持。
- DownloadJob只对显式`ByteResponseFlowControl.streamBackpressure`响应执行RIFF/ANMF frame credit；达到水位先flush authoritative partial，再停止下一次`moveNext()`，credit提高后同一response继续。
- HttpClient/rhttp direct声明stream backpressure；cache/resident/runtime整包fallback不做假pause。
- App删除已失去语义的50MiB动画whole-body预算设置；旧持久化key只被忽略。

## 可执行验证

- dev.205–dev.249 history/ownership gates：45/45 PASS，最多8 workers。
- core gates：10/10 PASS。
- Dart structure：361 files / 135 test files。
- Architecture / Plan / Handoff责任预算保持420 / 180 / 80行。
- `tool/check.sh`仍只在唯一dev.248基线缺失`third_party/source_archives/libwebp-1.6.0.zip`时入口停止。
- 当前环境无Dart/Flutter/Cargo，因此新增Dart行为测试、Flutter analyze/build、Rust tests不得宣称实际执行；Kotlin compile boundary实际通过。
