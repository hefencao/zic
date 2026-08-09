# ADR 0172：Venera Current-Only 动态抢占与 Request-Plan 分段观测

## 状态

Accepted。**Supersedes ADR 0171 的动态抢占触发规则**；保留 ADR 0171 的 scheduler-owned priority signal、request-plan/final-image ownership 边界与单 JavaScript invocation 约束。ADR 0169 的首次 previous=780 normal pressure仍有效。

## 新证据

`zic-debug-trace-2026-08-09T11-42-04.jsonl`显示 dev.188 体感恶化不能主要归因于最终图片网络：23个 origin 样本的 `sourceHostOpenMicros` 中位约0.399s、p90约1.460s；而 `sourceRequestPlanMicros` 中位约3.989s、p90约9.353s、最大约12.330s。对照 dev.187 的21个 origin 样本，host-open中位约0.331s、p90约2.063s，而 plan中位约3.467s、p90约5.421s、最大约6.935s。host-open没有同步恶化，plan尾部却接近翻倍。

同一 dev.188 trace 中，viewport边界可使同一个任务短时间出现 `780→900→780→900→1000`。ADR 0171 把所有 waiter priority变化和 active invocation降级都接到 `_maybePreemptControlledActive()`；priority变化是可逆的 viewport事实，而 cancellation不可逆，因此 transition抖动会把普通排序变化放大成 request-plan取消/重跑。

另一个稳定事实是 Venera plan依然呈串行阶梯：外层 NetLane 可同时 admission 1000/820/800/780/760，但 `sourceRequestPlanMicros`逐项累积，而最终 host-open通常远短。这说明修复 dev.188 抖动后仍需继续定位单 invocation内部究竟耗在 gate wait、hook还是hook内部 bridge network，不能继续只看聚合 plan时间。

## 决策

1. `PriorityObservableTaskControl` 与 NetLane active same-key实时rank信号继续保留；runtime仍只能观察，不能写rank。
2. Venera waiter首次进入繁忙gate时继续应用 ADR 0169 的既有规则：incoming priority>=780且比 active 至少高40分，可以请求一次controlled preemption。
3. **进入gate后的动态priority变化只有真正从低于1000跨入 current=1000 时才重新触发preemption判断。** `780↔900` transition抖动不得触发不可逆plan cancel。
4. active invocation自身从820/760等降级，不再因为动态rank事件主动取消。它完成后唯一permit仍按所有waiter的**实时priority**选择最高者，因此最新排序事实保留，但不把可逆demotion变成取消。
5. preemption仍不释放permit；旧 JavaScript invocation必须真实结束，Venera仍保持 `maxConcurrentInvocations=1`。
6. `ComicResourceRequest.diagnostics`增加只读source-plan元数据；transport/cache/retry/scheduler不得读取这些字段改变行为。
7. request-plan新增：
   - `sourcePlanGateWaitMicros`：Dart `_RuntimeInvocationGate` 等待唯一permit的时间；
   - `sourcePlanRuntimeInvocationMicros`：取得permit后到 runtime response返回的时间；
   - `sourcePlanHookMicros`：JavaScript `resolveResource`中解析/执行 `onImageLoad`/`onThumbnailLoad` config的时间；
   - `sourcePlanBridgeNetworkMicros` / `sourcePlanBridgeNetworkCalls`：该plan hook通过 `Network.*` 同一requestId发起的同步native bridge网络墙钟时间与调用数。
8. transport已有 `sourceRequestPlanMicros/sourceHostOpenMicros`继续保留；命中transport request-plan cache时不重复投影上一次hook/gate诊断，避免把历史耗时伪装成本次执行。
9. 不增加第二 JavaScript context，不整章预跑 `onImageLoad`，不改变 Reader 7/3、2/1、7/5/3/2、network/decode/upload 5/3/2、previous=780、current=1000、current reserved 1或40分门槛。

## 后果

- dev.188 的 transition/demotion cancellation churn被移除；真正晋升current仍能让低rank active plan及时让路。
- permit transfer继续按实时priority排序，因此不是退回固定FIFO。
- 下一份真机trace可以直接判断秒级plan主要是：等待单invocation、JavaScript hook计算/await，还是hook内部resolver网络。只有证据证明某一层是主要owner后，才讨论共享resolver state、缩小single-invocation临界区或其它结构调整。
