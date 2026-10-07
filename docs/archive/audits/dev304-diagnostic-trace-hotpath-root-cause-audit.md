# dev.304 纵排掉帧诊断 Trace 热路径根因审计

## 输入与边界

- 基线：0.31.0-dev.303。
- 已有设备事实：纵排抖动对应 30–50ms missed-vsync，而多数 build/raster 仅数毫秒；dev.301–303 已分别收口 semantic revision、lane transaction 与 DownloadSnapshot publication。
- 新增用户事实：此前尝试均未解决纵向滚动掉帧。
- 本轮没有把缺少的新设备 Trace 伪装成验证结果；根因来自剩余同步调用图与确定的算法复杂度。

## 为什么前几轮没有命中

一个真实页边界仍合法产生约 11 个 download priority migration、4 个 decode demand 和2个 upload demand，并在同一 UI isolate 记录对应 Trace。此前优化降低了 scheduler/session observer 工作，却完整保留了每个事件进入 telemetry/App projection 的同步成本。Flutter `FrameTiming.buildDuration/rasterDuration` 不包含帧间 microtask、trace compaction 和无监听者 `scheduleFrame`，所以这条链能够制造 missed-vsync 而不表现为高 build/raster。

## 源码根因

1. `TraceEvent._sanitizeTraceString()` 对 `download`、`reader:*`、`scrolling` 等显然不含 opaque locator 的普通字符串仍逐次构造并执行三组正则。合法 1/10/1 reconcile 会把该成本按事件和payload字符串放大。
2. `DebugTraceLog` 用 growable `List` 保存 500 条UI事件和10000条export事件；饱和后每次 `removeRange(0, overflow)` 搬移整个尾部。逐帧 `readerFrameTiming` 使export ring即使没有页面事件也会持续逼近并停留在最坏路径。
3. export coalescing 每次扫描完整 `_exportRangeFields`，为每个字段创建候选 list；bucket map 只用逻辑下标判断过期，不随淘汰删除旧key。
4. `_scheduleNotification()` 不检查 `hasListeners`。Reader route上没有 DebugTraceScreen 消费者时，普通observation/demand仍注册post-frame callback并请求frame。
5. `PipelineReaderSession` 的 `_memoryTrace` 没有任何生产/测试读取方，却复制本Reader全部事件并接收physical trace，且容量无上限。长会话会持续增加对象保留与GC压力。

## dev.304 收口

- telemetry预编译三组locator正则，并用`contains('venera')/contains('mihon:')`跳过普通字符串；既有脱敏回归保持。
- `MemoryTraceSink`改用`ListQueue`并支持可选容量；默认测试语义不变。
- `DebugTraceLog`的UI/export均改为`ListQueue`。export map引用具体entry，O(1)淘汰时按identity删除陈旧bucket；getter仍返回按时间排序的不可变快照。
- range merge只访问当前payload中的numeric allowlisted字段，直接更新min/max，不再扫描全集或分配临时候选list。
- 无listener时不再请求Flutter frame；同步export记录不变。
- 删除PipelineReaderSession不可见的私有memory副本，显式App sink与ref-counted shared physical sink继续分别承担Reader-local和composition physical诊断。
- 顺手修复`media_runtime_ownership_test.dart`直接使用`DecodeTarget`却漏导入其owner package导致的既有测试编译失败；没有通过重新导出生产类型迁就测试。

## 验证

- telemetry脱敏/有界memory测试通过。
- App DebugTrace ring、coalescing、export、无viewer不请求frame测试通过。
- Pipeline media runtime ownership测试通过，包括shared physical trace去重。
- 完整仓库/Flutter/Android/Rust结果记录在本次交付说明；真机视觉效果仍必须由同一区域profile/device Trace最终证伪。
