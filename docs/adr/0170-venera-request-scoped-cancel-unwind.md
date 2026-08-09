# ADR 0170：Venera Request-Scoped Cancel 物理闭环

## 状态

Accepted。补充 ADR 0166/0169；不改变 Reader 7/3、previous=780、current=1000、network=5+current-only 1，也不增加 Venera JavaScript 并发。

## 证据

`zic-debug-trace-2026-08-09T10-30-21.jsonl`中18个 origin样本已经由 dev.186 的 stage diagnostics拆开：`readMicros`中位约4.098s，`sourceRequestPlanMicros`中位约3.195s，`sourceHostOpenMicros`中位约0.367s；request-plan占总read时间的中位比例约83%。因此剩余长尾主要位于 source request-plan / Venera runtime，而不是外层 NetLane admission、decode/upload 或 host HTTP response-open。

大跳页中，旧 previous `identity:<-2b6457656dae1747,177>` 于30.733s以780进入network，31.459s仍处于非receiving而离窗取消；新 current `identity:<3f9259dd6af13569,179>`于31.460s立即以globalActive=6/handoffActive=1进入network，但其 origin response到35.894s才出现，其中`sourceRequestPlanMicros=3,446,541`、`sourceHostOpenMicros=974,441`。外层current handoff已及时，剩余问题是 requestId cancel到旧单invocation真正结束的物理unwind。

只读对照 VibeVenera：其 JavaScript bridge `delay`返回异步 `Future.delayed`，不会用同步睡眠占住bridge执行。ZIC则仍由native `Thread.sleep`处理`delay`；这不是设备trace能够证明当次一定命中的具体method，但它属于与单invocation cancel不兼容的明确阻塞风险。另一个可直接从代码确认的缺口是：ZIC request-scoped native cancellation登记 `HttpURLConnection`/call，却没有登记正在执行 blocking read 的 response `InputStream`。disconnect/call.cancel并不能替代对当前body stream的显式close语义。

## 决策

1. Venera bridge `delay`由JavaScript侧使用WebView原生 timer实现异步Promise；timer按当前requestId登记。`__zicCancel(requestId)`清除该request的timer并立即reject对应Promise。
2. native bridge不再执行 `Thread.sleep` delay；若未经过JavaScript async path而直接请求native `delay`，视为contract violation。
3. URLConnection与DNS-fallback HTTP body的 response `InputStream`在读取期间登记到已有requestId cancellation集合，并在finally中注销。`bridge.cancel(requestId)`因此会同时disconnect/cancel owning connection/call并close正在阻塞的body stream。
4. cancellation仍不提前释放 Venera invocation permit。唯一permit继续等待旧JavaScript执行finally并调用真实 `finished(requestId)` 后才转交；`maxConcurrentInvocations=1`不变。
5. 不调整NetLane priority、并发、水位、decode/upload，也不增加第二JS context。若dev.187后`sourceRequestPlanMicros`仍有秒级长尾，下一步必须先增加Venera operation/hook/bridge-stage timing，而不是扩大并发。

## 后果

- JavaScript插件使用delay等待时可以被同一requestId cancellation及时打断，而不会把唯一invocation锁在native sleep。
- 已进入HTTP body read的request可以通过close精确唤醒blocking `InputStream`，让physical unwind更接近cancel发生点。
- 单invocation安全边界不变；抢占仍通过“取消旧request并等待finished”实现，而不是并行执行两个插件调用。
