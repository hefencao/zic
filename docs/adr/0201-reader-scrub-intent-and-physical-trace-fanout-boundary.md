# ADR 0201：Reader scrub intent 与 physical trace fan-out 边界

- Status: Accepted
- Version: 0.31.0-dev.220

## Context

dev.219 已把 Reader observation 改成 enqueue-only，并把 DecodeTarget 与 navigation 生命周期拆开。09:44 真机 Trace 证明 late Reader decode/upload 已恢复，但暴露出两类剩余耦合。

第一，slider `onChanged` 仍逐格调用 `ReaderController.requestPage()`。一次约 148→248 的拖动在约 0.4 秒内产生 23 次 `pageCurrent`、23 次 policy replan、157 次 download priority 重排和大量 demand remove/add；UI scrub 中间值因此被误当成正式 navigation commit，PageView、Pipeline 与 physical transfer window 被同步拖动。

第二，composition physical runtime 的 `_TransferTraceHub` 挂载每个 Reader 的 `MultiTraceSink(memory + shared app sink)`。两个 Reader 重叠时，同一 physical event 会经两个 wrapper 再写回同一个 shared sink。09:44 Trace 中出现 1120 组逐字段完全相同的紧邻重复 physical events；单 Reader 区间为 0，重叠 Reader 区间成片出现。

同时 `ReaderBinding.accept()` 仍先执行 pipeline/coordinator reconcile，再同步 viewport/playback；外层虽已隔离异常，但 lane reconcile 失败仍可阻止 Reader-local viewport projection 前进。

## Decision

1. slider 拖动中的索引是 UI-local scrub preview，不是 Reader navigation command。`onChanged` 只更新局部 thumb/preview label；`onChangeEnd` 才向 `ReaderController.requestPage()` 提交一次目标页。
2. `ReaderController.requestedIndex` 继续表示“已经提交但尚未被 viewport acknowledge 的 navigation intent”，不再承担拖动中的临时 scrub state。
3. `ReaderBinding.accept()` 先解析并保存 Reader-local viewport fact；pipeline reconcile 可失败并上报，但 playback projection 必须在 `finally` 中按当前 plan 同步，不能因 lane failure 跳过 viewport/presentation 更新。
4. composition physical trace fan-out 分为两类 sink：每 Reader 独立 memory sink，以及共享 App/export sink。共享 sink按对象 identity 引用计数，多个 Reader 同时引用时只记录一次 physical event；Reader-local memory projection仍各自保留。
5. consumer-specific transfer events仍由该 consumer 的 trace sink记录；本 ADR只去除 composition physical event 对同一 shared sink 的 N×Reader 放大。
6. 不修改 NetLane、network/decode/upload并发、水位、retry、cache、transport、TransferKey 或 verified equivalence。

## Consequences

- slider远距拖动不会再逐页驱动 PageView 与 demand window；release后只发生一次正式 navigation transition。
- physical download/prefetch不会因用户在 slider 上预览大量中间页而被反复取消、降级、重排。
- pipeline lane异常仍可被诊断，但 Reader-local viewport/playback事实继续前进。
- overlap Readers 不再把同一 physical event重复写入全局 Debug Trace，降低诊断噪声与同步trace开销，同时保留各Reader本地memory trace。
