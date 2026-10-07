# dev.271 transport lease / source-open latency 审计

## 设备证据

输入：`zic-debug-trace-2026-08-14T01-26-24.jsonl`（dev.270）。

- 完成的真实 `source-loader` open 中位约 1.60 s，P90约 3.42 s，最大约 6.07 s；persistent-artifact 本地 open 中位仅约 1.7 ms。
- 56个 origin open 观测中，`sourceRequestPlanMicros` 中位约 1.02 s；对照上一份 dev.269 Trace 约 0.48 s。`sourceHostOpenMicros` 中位约 0.62 s、P90约 1.95 s。
- 所有可见真实 origin HTTP version 均为 HTTP/1.1。
- `globalRunning` 在长会话中达到约17–20；inactive parked response 观测值曾达到16，再加 demanded parked，明显超过冻结 normal5。
- page133 晋升 current 后约33 ms即 `downloadStarted`，证明外层NetLane task admission不是主等待；但 origin open 仍耗约2.47 s，其中 request-plan/runtime bridge约2.06 s、host open约0.41 s，首帧约3.17 s。

## 根因

dev.268 正确把“是否请求下一块body”与“response是否仍活着”分开，但把 normal5 重新解释成只有 body-read permit。dev.269 又用独立 parked-response 数量处理 response retention。这产生两个容量 owner：body-read 5路与 parked response pool；一个 live HTTP/1.1 response 在park后不再消耗前者，便可以不断新增 source task，最终让实际 live source/response 数远高于5。

这同时放大两段延迟：

1. 更多 source task 竞争 Venera 单 invocation request-plan gate；
2. 更多未消费完的HTTP/1.1 response长期持有host connection/socket资源。

因此不能用“把 inactive parked 10 调成5/20”、缩3/7、提高current priority或预解析整章修复。需要把 transport/source lease 作为真实一等资源重新归NetLane所有。

## 实现审计边界

- NetLane同时计数 `transportLeases` 与 body-read `active`；normal上限仍是5，current handoff仍是1。
- parked live source response：`active`减少，`transportLeases`不减少。
- durable artifact local body：两者都减少，`running`可继续。
- 删除 `maxInactiveParkedResponses` production owner与Reader相关容量推导。
- normal transport pressure只淘汰无consumer的inactive parked transport lease；demanded parked response不因普通预下载压力销毁。
- current live response reacquire仍不需要新transport open；current新transport使用reserved/high-priority统一调度。

## 真机判据

- normal steady state `globalTransportLeases <= 5`；current handoff期间最多6。
- `globalRunning`可以高于transport leases，但高出的必须能由local artifact/non-network physical task解释。
- `globalDemandedParkedResponses + receiving network tasks`不再导致HTTP/1.1 live response数量无界增长。
- `sourceRequestPlanMicros/sourcePlanGateWaitMicros/sourceHostOpenMicros`应相对dev.270明显回落；若仍慢，再分别下钻Venera request-plan gate和host open，不能继续改body chunk或3/7。
