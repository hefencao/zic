# ADR 0171：Venera 动态 Priority 观察与 Request-Plan 边界

## 状态

Accepted。补充 ADR 0166/0169/0170；不改变 Reader 7/3、previous=780、current=1000、network=5+current-only 1，也不增加 Venera JavaScript 并发。

## 问题

`zic-debug-trace-2026-08-09T11-04-46.jsonl`显示 dev.187 已把外层 NetLane admission 与 request-scoped physical cancel向正确方向收敛，但单 Venera invocation gate 仍存在动态rank丢失：已经取得 NetLane slot、随后在 runtime gate 等待的任务，priority 可以随viewport从 previous 780→transition 900→current 1000；gate的waiter排序虽然每次读取 `TaskControl.priority`，preemption却只在首次发现gate繁忙时触发一次。waiter之后升为current不会主动重新比较正在执行的低rank invocation。

典型 identity `<11b9bd697df028d4,178>` 在24.004s以780开始，27.314s升900、27.402s升1000，最后 request-plan仍累计5.327s。第二个 identity `<-486a5b2f015a4cad,178>`同样从780升到1000且 request-plan约5.943s。外层rank事实已经变化，但内部唯一permit没有得到事件通知。

## 边界澄清

Venera source contract不是“JavaScript下载最终图片”。章节加载先提供page identity/locator；对于声明了 `onImageLoad` 的来源，真正打开该页前仍可能按需执行一次异步hook以生成 URL/method/headers/body 等 request plan。EHentai一类source的hook可能包含resolver网络，因此plan不是纯字符串拼接。plan完成后，可无状态重放的最终图片body由 `SourceResourceTransport`注入的native host transport执行。

因此：

- `__zicCancel(requestId)`只属于当前 JavaScript request-plan invocation，负责让hook/timer及该hook通过bridge发起的request-scoped工作停止；
- 最终图片HTTP由同一scheduler `TaskControl`贯穿的host transport取消，不能由`__zicCancel`再拥有第二套取消语义；
- 不把整章所有 `onImageLoad` 预先执行，因为这会把按需resolver变成全章前置工作并改变来源时序/网络语义。

## 决策

1. `TaskControl`保持scheduler-owned；新增可选 `PriorityObservableTaskControl.priorityChanges`，只暴露rank变化事件。
2. `NetLane.CancelToken`实现该接口。active same-key原位priority migration继续由NetLane决定，同时向已有下层消费者发布变化；token task结束后关闭信号。
3. Venera `_RuntimeInvocationGate`若收到可观察control：
   - queued waiter priority变化时，立即用新的实时rank重新比较当前active invocation；
   - active invocation priority变化时，用当前最高waiter重新比较；
   - waiter取消、grant、runtime close或active release时注销订阅。
4. 所有重新比较仍使用既有controlled floor=780与preemption threshold=40；只有scheduler rank事实改变，runtime无权自行提升/降低priority。
5. 发出preemption request不释放permit；旧 invocation必须真实退出并触发`finished(requestId)`，下一请求才能进入，`maxConcurrentInvocations=1`保持。

## 后果

- previous在等待期间升级成current，不再等到另一个页面事件碰巧重新触发runtime gate。
- active plan离开viewport而降级时，已经等待的previous/current可以立即形成真实pressure。
- 保留单WebView/单invocation安全边界，不通过增加JS并发掩盖内部队列失真。
- `__zicCancel`职责更清楚：它是plan invocation cancel，不是最终图片下载cancel。
