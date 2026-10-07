# dev.248 验证结果

## 候选

- Source：`0.31.0-dev.248`
- App：`0.31.0+248`
- 唯一代码基线：`zic_v0.31.0-dev.247_animated-webp-layered-prefetch-window.zip`
- 真机证据：`zic-debug-trace-2026-08-12T14-13-54.jsonl`

## Trace 结论

- 共6756条事件；`downloadPreempted=13`，dev.246的stable-current destructive preemption已继续降低cancel churn，但dev.247仍未让50MiB真正约束同时执行的动画工作。
- 动画2/4 lower-window共46次有效决策均估算72MiB并超过默认50MiB；dev.247仍保留7个network demand，因此budget主要只是诊断/outer-page过滤，不能约束lower-window active execution。
- dev.248把previous2/next4重新定义为最低预下载资格；水位仍只扩候选到previous3/next7。每个eligible动画DownloadDemand携带估算body成本与50MiB budget，NetLane按active speculative bytes执行weighted admission；current/visible transition前台绕过预算但保留成本元数据，降为background后原physical task立即计入预算且不因超预算被cancel。
- 未知页按12MiB估算时，默认50MiB通常最多允许4个speculative动画transfer同时active；其余2/4或水位扩出的页面仍在同一rank队列中，不被误判离开3/7逻辑/retention window。

## 工作树验证

- dev.205–dev.248 history/ownership gates：44/44 PASS，最多8 workers。
- documentation responsibility：PASS；Architecture 420行、Implementation Plan 180行、Next Handoff 80行，未放宽职责预算。
- Dart structure：PASS（359 Dart files / 134 test files）。
- Pipeline runtime boundary / demand stability / Reader streaming / UI architecture / test quarantine / Android runtime dependency / texture Kotlin compile / dev.139 current-documentation：10/10 PASS。
- `tool/check.sh`仍在入口仅因唯一dev.247基线缺少 pinned `third_party/source_archives/libwebp-1.6.0.zip`停止；没有从旧包或文件库补入。
- 当前环境无 Dart/Flutter/Cargo，因此没有宣称执行 Dart/Flutter/Rust行为测试或APK build；Kotlin compile gate实际执行通过。

## 新合同静态/行为源码覆盖

- `AnimatedPrefetchPolicy`只拥有3/7内的animation prefetch eligibility：2/4最低资格，waterline逐层加入next5/previous3/next6/next7；byte budget不再删除eligible demand。
- `DownloadDemand -> TransferDemand`携带`estimatedTransferBytes/speculativeBudgetBytes/speculativeBudgetExemptPriority`；这些network scheduling metadata不进入DecodeDemand/UploadDemand。
- `NetLane`唯一执行active speculative byte accounting；默认50MiB、未知12MiB时6个eligible speculative候选只能先运行4个，current仍可立即运行且不计speculative budget。
- foreground physical task降为background时保留原cost metadata并立即计入active budget；budget overflow只阻止新的speculative admission，不cancel已经admit的task。
- 单个eligible page若自身估算超过整个budget，在没有其他speculative active时允许单独运行，避免永久饥饿。
