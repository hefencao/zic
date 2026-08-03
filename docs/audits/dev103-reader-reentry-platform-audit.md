# dev.103 Reader 重进与 platform presentation 审计

## 问题清单

### 编译错误

- 本轮输入未报告新的编译错误；新增 API 必须由 Kotlin stub、Dart structure 和引用门禁覆盖。

### 产品错误

- 本地 WebP 前几帧仍明显卡顿。
- 退出 Reader 后再次进入更卡。
- Flutter DevTools 的 build/layout/paint/raster 较低，说明卡顿不能归因于 Widget 构建或 raster workload。

### 性能问题

- dev.102 Trace 的主要 presentation 长尾位于 platform main-queue 等待与 channel acknowledgement，而 `scheduleFrame()` 调用本身通常较短。
- 单一全局 blit lane 和默认 platform MethodChannel handler 会把不同 output、旧 Reader 与新 Reader 的工作耦合到同一串行链。
- playback timer 从 Future 回包后才启动，使确认延迟被逐帧加入帧时长。
- 每 Reader 独立 stopwatch 使两个 session 的 Trace 时间轴不可比较。
- decoded role 晋升为 current 后的正常预解码 lead 被误记为 upload backpressure。

### 测试错误

- 旧 Trace analyzer 将独立 session clock 合并计算跨 session 并发，结果无效；旧 Trace 只能报告 per-session concurrency。

## 所有权清单

| 状态/资源/命令 | 当前所有者 | 正确所有者 | 处理 |
|---|---|---|---|
| monotonic epoch | 每个 Pipeline Reader session | `telemetry` 进程级 | 改为共享 epoch |
| Reader lifecycle telemetry | 无完整事件 | `pipeline_runtime` | 增加 create/dispose-start/disposed |
| native frame blit 串行 | texture 插件单 lane | `texture_bridge` | 两 lane，output 稳定绑定 |
| platform handler | 默认 main queue | `texture_bridge` | background task queue；仅平台 API 回主线程 |
| playback deadline | `sessions` | `sessions` | 有界 acknowledgement credit |
| role promotion timing | `sessions` | `sessions` | promotion 等待归 lead |

## 被否决方案清单

- 不通过降低 7/3、2/1、5/3/2 或关闭预下载掩盖队列问题。
- 不在 Reader/App 增加私有纹理、最后一帧或 decoded byte cache。
- 不在未执行 `scheduleFrame` 前提前回复 MethodChannel。
- 不使用无限制 ack 回溯；最多抵扣一个名义帧周期。
- 不根据旧独立 clock Trace 宣称跨 Reader 并发或生命周期顺序。

## 输入 Trace 结论

输入仅用于定位 dev.102 行为。它支持 platform queue/channel 路径存在长尾及重进退化，但由于独立 session clock，不能可靠证明两个 Reader session 的全局重叠顺序。修复效果需要 dev.103 Trace 复验。
