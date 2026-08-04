# dev.114 纵向静态 Demand 与内存预算审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.113_texture-pool-direct-artifact-ingress.zip`。
- 动画/加载 Trace：`zic-debug-trace-2026-08-04T02-16-30.jsonl`。
- 纵向静态 Trace：`zic-debug-trace-2026-08-04T02-21-15.jsonl`。
- 编译报告：`错误报告(54).txt`。

## 证据结论

- dev.113 direct durable ingress 和 Android platform presentation 已明显缓解动画加载；剩余长尾需继续由设备复验比较。
- 纵向静态旧样本中 8 个页面 host 被 dispose，其中 4 个在 dispose 前从未得到首帧。
- ListView 可挂载比 Pipeline 7/3 的 decode/upload 投影更远的宿主；旧策略只根据中心 logical position 和固定 transition threshold 建立 demand，因此出现已挂载但无 decode/upload 的伪 loading。
- 页面仍部分可见时，target fraction 下降到阈值以下会撤销 transition，已有 output 随 `demand-detached` 被释放。
- 编译报告证明 `PipelineMediaRuntime` 不能直接传给无继承关系的 `PipelineOutputPrewarmer` 参数。

## 修改与所有权

| 问题 | 所有者 | 修改 |
|---|---|---|
| 纵向 demand 等待中心交接 | `reader` + `pipeline` | 真实视口交叠和方向投影 |
| 已挂载宿主无首帧 | `pipeline` | 静态邻页 budgeted decode/upload |
| 静态 output 过快回收 | `sessions` 既有 FrameBudget + `pipeline` priority | 96 MiB 推测选择、128 MiB 实际裁决 |
| Widget host dispose 过快 | `reader` | 静态纵向 cache extent 4 屏 |
| output prewarm 类型错误 | `pipeline_runtime` | 显式 capability cast |

## 生命周期检查

- 静态 warm 只建立 Pipeline demand，不由 Widget 直接加载图片。
- 每个静态页只解码一帧；动画页仍使用 staged 多帧水位。
- 96 MiB 仅用于策略选择，不能绕过 128 MiB FrameBudget。
- current、transition、last output 继续拥有更高回收优先级。
- 增大的 ListView cache extent 只保留轻量 host，不持有 texture lease 或 decoded bytes。

## 未验证

dev.114 尚未在设备运行，不能把纵向预加载、dispose 和内存预算效果写成已验证事实。
