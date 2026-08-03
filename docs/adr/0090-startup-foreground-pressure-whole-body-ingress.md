# ADR 0090：Reader 启动前景背压与整块 artifact ingress

**状态：Provisional**

## 问题

dev.105 已将 promoted artifact 整文件 materialize 降到毫秒级并加入 encoded-byte LRU，但 materialize 返回后仍把 5–18 MiB bytes 拆成 1 MiB response chunks，逐块写入 Reader 临时 artifact 和 native ingress。更严重的是，foreground scheduler lease 在 materialize 完成后立即释放；current 尚未形成首帧和 successor 水位时，多个 background session-copy 已同时进入 artifact writer、ingress、decode 和 texture 提交链。

设备 Trace 表现为 Flutter build/layout/paint/raster 很低，但首帧和前几帧仍出现秒级端到端延迟；待 background 完整复制结束后，切页明显变顺。

## 决策

1. current/transition 的 promoted bytes 由 `ArtifactCacheTransport` 作为一个 immutable response body 提交；background 继续使用 1 MiB chunk quantum。
2. foreground read scheduler lease 覆盖 materialize 和 response body consumption，直到 body drain 或 discard 才释放。
3. `PipelineReaderSession` 在首次 `binding.accept()` 之前建立 composition 级 foreground pressure hold，避免协调器同步提交 background 时抢占全部本地读槽。
4. pressure hold 不消耗 read slot，只把 foreground 压力期的 background 同时活动量限制在既有上限。
5. current output 已实际呈现，并且 decode successor depth 达到 2，或媒体被权威确认静态/结束/失败时，释放 pressure hold。current 变化、Reader detach/dispose 时同步迁移或释放。
6. 不增加 Reader 私有缓存、不取消 active artifact stream、不缩小下载或预解码窗口。

## 边界

- `downloads` 拥有 artifact read scheduler、body delivery 和 lease。
- `pipeline_runtime` 只把权威 current 生命周期投影为 foreground pressure；不拥有 transport 实现。
- `sessions`、native ingress、decode/upload lane 与 Android texture 所有权不变。
- 该方案在设备复验前不得描述为已解决启动卡顿。

## 解除 Provisional 条件

同一设备和 fixture 的 dev.106 Trace 证明：current `deliveryMode=whole-body`；启动期 `readSchedulerPressureHolds>0`；background 不再在 current 首帧前形成多流灌入；首帧与前 12 帧端到端长尾下降；pressure 在 current 已呈现并达到 successor 水位后释放，且 7/3 background 最终继续推进。
