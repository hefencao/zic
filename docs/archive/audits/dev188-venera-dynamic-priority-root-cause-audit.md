# dev.188 Venera 动态 Priority 根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.187_venera-request-scoped-cancel-unwind.zip`。
- 设备证据：`zic-debug-trace-2026-08-09T11-04-46.jsonl`。
- 只读接口核对：Venera source contract 与 VibeVenera request-plan调用位置；不复制第二套scheduler。

## 设备事实

21个带dev.186 stage diagnostics的origin样本中，`sourceRequestPlanMicros`约1.229–6.935s，中位约3.467s；`sourceHostOpenMicros`中位约0.331s。剩余主要长尾继续位于request-plan/runtime，而非decode/upload或普通host open。

更关键的是动态rank事件：

- `identity:<11b9bd697df028d4,178>`于24.004s以previous=780进入NetLane；27.314s升900，27.402s升current=1000，但origin直到30.391s出现，`sourceRequestPlanMicros=5,326,859`。
- `identity:<-486a5b2f015a4cad,178>`于41.318s以780进入，45.634s升900，45.708s升1000；origin记录`sourceRequestPlanMicros=5,942,947`。

NetLane active token的priority确实原位变化；Venera gate waiter会在最终permit transfer时读取最新priority，但没有priority-change事件，因此waiter升为current本身不能重新触发active request-plan preemption。这是明确的控制面传播缺口。

## 接口边界

章节`loadEp`与图片request-plan不是同一阶段。page locator可先持久化；如果source声明 `onImageLoad`，该hook在按需图片加载前仍可异步计算request config，某些source还会通过bridge执行resolver网络。随后真正的图片body由native `SourceResourceTransport`打开。

因此 dev.187 的 `__zicCancel(requestId)`不是最终图片HTTP cancel。它只终止JavaScript plan invocation以及该hook在bridge中以相同requestId启动的timer/network/body-read。最终host HTTP仍由Reader/NetLane的同一`TaskControl`负责。

## 修改

- 新增scheduler-owned `PriorityObservableTaskControl`。
- `NetLane.CancelToken`在active原位rank变化时发布事件；task完成后释放信号资源。
- Venera gate监听queued waiter和active invocation的priority变化并重新应用既有780 floor/40 threshold；取消/grant/release/close都清理订阅。
- 明确Android Venera cancel注释：bridge/requestId只覆盖source hook plan；最终图片body属于后续host transport。
- 不预解析整章`onImageLoad`，不增加第二JS context，不调整7/3、5/3/2或780/1000。
