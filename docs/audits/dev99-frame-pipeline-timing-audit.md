# dev.99 前几帧端到端耗时审计

## 问题清单

### 编译错误

- `错误报告(50)` 暂未报告新的 analyzer 编译错误，但当前工作树新增 `FrameDecodeTiming`、`OutputFrameTiming` 与 Android texture telemetry 字段，必须全仓搜索所有实现、构造器与测试替身，避免无 SDK 环境漏迁移。
- Android Kotlin `present` 结果由标量 Map 扩展为阶段化结果，必须保持 MethodChannel 返回类型和 Dart 解析字段闭包。

### 产品错误

- 本地 WebP 前几帧仍可能停顿数秒；现有 trace 不能把 source 等待、decode lane、worker queue、native decode、upload lane、output prepare、平台队列、RGBA copy、Surface replace、MethodChannel 回调和最终 present 分开归因。
- 首 12 帧被诊断导出按时间桶合并，导致关键启动阶段样本丢失或被 min/max 摘要覆盖。
- `raster_plan_test` 与 `webp_preview_test` 显示“小目标不放大”的产品合同和当前 renderer/filter 投影存在冲突，需要以不裁切、目标小于 8 px 不被错误放大的现行合同为准核对。

### 性能问题

- 已有设备 trace 中 native decode 常为几十毫秒，但部分 Android present 往返达到数百毫秒；当前 `bridgeMicros` 把平台执行、结果派发和 Dart 回调混成单值，无法确定主阻塞点。
- worker 被分配前的进程级 decode pool 排队、分配后的 isolate 往返与 native decode 未拆分。
- UploadSession 只能看到 upload 总时长，不能区分 decode 完成后等待 upload lane、output 构造、output ready 后等待 UI present。
- 必须控制 trace 体积：只对每个 output identity 的前 12 帧逐帧记录，后续仅记录端到端 >=250 ms、present >=100 ms、单阶段 >=100 ms、deadline miss 或错误。

### 测试错误

- `错误报告(50)` 包含 12 项失败：tiny raster、debug trace build 通知、Reader 控件/分类器、Library UI、Source Browser 以及 WebP filter quality。必须区分产品退化与过时/脆弱测试，不得统一改测试绕过。
- 若新增 timing capability，测试替身不得被迫实现仅诊断能力；应保持 capability 可选并增加拥有 package 的精确回归。

## 所有权清单

| 状态/资源/命令/生命周期 | 当前所有者 | 正确所有者 | dev.99 处理 |
|---|---|---|---|
| decode lane 排队时间 | `sessions/LiveCoordinator` | `sessions` | 在任务实际开始时计算并下传只读数值 |
| process decode worker 排队与 worker identity | `bridge/NativeDecodeWorkerPool` | `bridge` | 记录 queue、worker round trip、worker index，不向 Reader 暴露 worker 对象 |
| native demux/libwebp decode 时间 | `media_core` FFI + `bridge/NativeFrame` | `media_core` 产生、`bridge` 投影 | 保持 native telemetry 为权威，不由 App 推算 |
| decoded frame 到 upload 开始 | `sessions/UploadSession` | `sessions` | 由同一 MonoClock 计算 |
| upload lane 排队 | `sessions/LiveCoordinator` | `sessions` | 下传至 UploadSession |
| Android texture queue/copy/schedule/replace/result callback | `texture_bridge` | `texture_bridge` | Kotlin 采样，Dart 只读投影 |
| end-to-end frame timing 关联 | `sessions/UploadSession` | `sessions` | 按 frame identity 关联 decode、upload、present；不创建第二套调度状态 |
| trace 事件与 identity 脱敏 | `telemetry` | `telemetry` | 新增权威 event kind |
| 导出限流/合并 | `apps/app/DebugTraceLog` | App 诊断投影 | 首帧 timing 不合并，普通高频事件继续有界聚合 |
| Reader 页面与播放 | `reader_runtime`/Pipeline facade | 不变 | Reader 不读取 timing、不控制 lane/session/texture |

## 被否决方案清单

- 不通过缩小 7/3 下载窗口、2/1 预解码窗口、降低 lane 并发或关闭 successor 预解码掩盖停顿。
- 不在 Reader/App 增加帧字节缓存、最后一帧缓存、私有 stopwatch 状态机或第二套 texture 生命周期。
- 不把所有帧的所有阶段永久逐条输出；这会重新制造数 MB trace，且影响播放线程。
- 不继续使用一个模糊的 `bridgeMicros` 把 Android queue、copy、schedule、replace 和回调派发混为一类。
- 不使用 wall clock 跨 isolate/平台拼接；只使用各拥有层的单调时钟并传递阶段 duration。
- 不为通过测试恢复 tiny target 错误放大、脆弱文本 finder、固定 pump 或双份 UI 入口。
