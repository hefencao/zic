# ADR 0280：调度语义 revision 与 demand liveness 解耦

## 状态
Accepted。

## 设备证据
11:43 dev.300 Trace 首次把明显纵排抖动与真实 Flutter cadence 对齐：759 个 `readerFrameTiming` 中基准约 16.4ms，但约 37 个间隔跨 2–4 个刷新周期，滚动中多次出现约 29–52ms frame interval；其中代表性长间隔约 52.6ms / 46.4ms / 43.7ms，而对应 build/raster 仅约 1.65/1.09ms、5.96/1.17ms、1.49/0.94ms。故“大幅跳动”来自 missed-vsync，而不是 1–2px geometry/texture seam，也不是 build/raster 本身持续超预算。

同一时间轴暴露同步 scheduling churn。约 15.380–15.387s，远端 page16–19 的 WebP transport evidence 变化连续产生 rev46–49；约 15.440–15.461s，page8→5 的 WebP observed 又产生 rev51–54。每轮真实计划均保持 11 downloads / 4 decodes / 2 uploads、current=12、target=13、`animatedFlowActive=false`、所有 frame target=0；变化只在 `runtimeWebpCostPages` 诊断计数。但每个 revision 都重新发出 4 个 `decodeDemand` + 2 个 `uploadDemand`。

## 根因
`observeWebpTransportCost()` / `classifyPage()` 把任意 runtime evidence 变化都 `force:true` 进入 `_replan`。旧 `_replan` 在确认新计划语义前先递增 revision；而 `Demand` 的对象 equality 包含 `expirationRevision`。于是即便 policy 结果完全不变，新 revision 也会让所有 demand 被 `DemandDiff` 视为 changed，`LiveCoordinator` 在 UI isolate 同步执行 follow/submit/reconcile。多个后台 source sniff 微任务可在数毫秒内形成 revision cascade，工作发生在 Flutter build/raster 计时区间之外，却占用 UI isolate 并错过 vsync。

## 决策
1. `expirationRevision` 只属于 demand liveness，不属于 scheduling identity。Download/Decode/Upload scheduling identity继续包含 role、priority、reason及各自 flow/watermark/decision 字段。
2. `DemandDiff` 只比较 scheduling identity。新 plan revision 中语义未变的 demand不得进入 changed。
3. `LiveCoordinator` 先仅对 semantic diff执行 cancel/submit/follow，再把新 plan 的 expiration/liveness metadata 原位刷新到所有 surviving demand；不得为了刷新 expiration 重排已有 task。
4. `PipelineController` 使用 candidate revision建立 proposal/guard/diff；若 window/decode-target不变且 semantic diff为空，则保留 runtime evidence 事实，但不得提交 revision、`policyDecision` 或 coordinator update。
5. download scheduling diff为空时不得调用 physical transfer `replaceDemands`。
6. Flutter `FrameTiming` 是批量历史回调；Reader不得把 callback 时刻的 scroll/current/interaction伪装成每个历史 frame 的状态。保留 `vsyncStartMicros`、frame interval与 batch callback/last-vsync anchors供时间轴重建。

## 不改变
previous3/next7、decode previous1/next2、dev.295 hidden-static upload、dev.299 `current±2` static presentation continuity、NetLane、sourceCanvas、retention、Reader geometry/presentation均不改。

## 可证伪条件
下一份同区域 Trace 中，offscreen `runtime-transport-cost`/static classification若不改变权威计划，不得紧跟新的 `policyDecision`、decodeDemand/uploadDemand；真实 page/role/flow变化仍必须正常晋升 revision。若 revision cascade消失但仍存在大量 30–50ms frame interval，再沿 UI-isolate 其他同步工作或 platform scheduling继续下钻，不回退到像素级补偿。
