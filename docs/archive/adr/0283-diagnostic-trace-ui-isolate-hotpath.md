# ADR 0283：诊断 Trace 不得占用纵向滚动帧预算

## 状态

Accepted

## 背景

dev.300 的真实 Flutter `FrameTiming` 已证明明显纵排抖动来自 missed-vsync，而不是持续超预算的 build/raster。dev.301–303 依次删除语义空转 revision、重复 lane pump 和诊断事件隐式 snapshot 广播后，用户仍确认既有尝试没有解决掉帧。剩余同步链中，合法页边界仍会在 UI isolate 连续记录 download/decode/upload demand 与 observation 事件。

源码审计发现这些诊断本身不是常数成本：`TraceEvent` 对每个普通字符串都重新构造三组 `RegExp`；`DebugTraceLog` 达到 500/10000 条上限后每次从列表头部搬移其余元素，export bucket 索引不会随淘汰删除，合并事件还会扫描完整 range-field 表；即使没有 Trace 查看器监听，普通事件仍请求额外 Flutter frame。`PipelineReaderSession` 同时把所有事件复制到一个无公共读取方、无容量上限的私有 `MemoryTraceSink`。这些工作发生在 Flutter build/raster phase 之外，与已有 cadence 证据吻合，并会随滚动时长与事件密度恶化。

## 决策

1. locator 脱敏语义保持不变，但正则表达式只初始化一次；普通字符串先用廉价 scheme marker 判断，未包含 Venera/Mihon locator 时不得进入正则匹配。
2. Debug Trace 的 UI/export 投影使用队列式有界 ring，头部淘汰必须为 O(1)。export bucket 直接引用仍存活 entry；entry 淘汰时同步移除仍指向它的 bucket，禁止遗留无界索引。
3. range 合并只遍历当前事件实际携带的数值字段，再以 allowlist 过滤；不得为每个 scroll/frame 事件扫描完整字段全集或为每个候选创建临时 list。
4. 没有 Debug Trace UI listener 时，记录事件不得调用 `scheduleFrame`。Trace 数据仍同步进入有界 export ring，打开查看器后首个 build直接读取当前快照。
5. `PipelineReaderSession` 不再保留无人消费的私有全量 memory trace。显式注入的 App TraceSink 是 Reader-local事件的唯一生产诊断出口；composition physical trace 仍通过原有 ref-counted shared sink 去重。`MemoryTraceSink` 作为测试/工具能力保留，并提供可选 O(1) 有界容量。
6. 本决策不改变 Reader observation latest-wins microtask、DemandPlan、Net/Decode/Upload lane、3/7、decode 2/1、NetLane、geometry、sourceCanvas、texture 或 presentation 生命周期。

## 可证伪条件

同一区域真机复测时，合法页边界 `pipelineReconcileTiming` 与 30–50ms `readerFrameTiming.frameIntervalMicros` 应同步下降，长时间滚动也不应因 Trace ring 饱和而恶化。导出仍须保留同样的错误/生命周期边缘、语义分桶、first/last/count 和数值 min/max；Venera/Mihon opaque locator 不得泄漏。若诊断热路径收口后 missed-vsync 仍大量存在，下一步只调查剩余 UI-isolate/platform callback scheduling，不回到 geometry、scale、pixel-snap 或扩大资源窗口。
