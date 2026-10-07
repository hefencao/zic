# ADR 0098：纵向真实可见 Demand 与静态输出内存预算

**状态：Provisional**

## 问题

设备 Trace 显示，纵向静态章节中页面宿主可能已经进入 ListView 缓存范围甚至部分进入真实视口，但 Pipeline observation 仍按视口中心推导 target。结果是相邻页需要接近中心交接后才获得 transition decode/upload；部分已挂载宿主从未得到首帧便被 dispose，UI 长时间停留在 loading。

固定的动画帧水位也不适合静态页：静态图片每页只需一个 output，内存充足时可保留更多 last/previous/next；内存紧张时又应由实际字节预算回收，而不是固定页数永久保活。

## 决策

1. 纵向 Reader 使用页面与视口的真实交叠比例生成 observation。滚动方向上的相邻页只要进入视口（coverage > 0）即成为 transition；分页模式仍保留既有 transition threshold。
2. 静态页面不使用动画 c/n/m/p 多帧水位。`HeuristicPolicy` 在既有 7/3 窗口内按角色优先级、距离与估算 RGBA 字节选择静态 warm 页面，每页 decode watermark 为 1，并同时建立 upload demand。
3. 静态 warm 推测预算为 96 MiB；实际 output 仍由 session 的 128 MiB `FrameBudget` 统一裁决。current、transition、last 优先，低优先级静态邻页在超限时先回收。
4. 静态纵向 ListView 的轻量 host cache extent 从 2 屏增加到 4 屏。该 host 缓存不持有 texture、decoded frame 或 cache body；重资源生命周期仍属于 Pipeline、Sessions 与 FrameBudget。
5. 动画页面继续使用 staged c/n/m/p 8/6/4/3、last keep 与既有下载/解码调度。
6. output prewarm 通过显式 `PipelineOutputPrewarmer` capability narrowing 使用，不要求 `PipelineMediaRuntime` 在类型层继承该接口。

## 所有权

- 视口几何和滚动方向：`reader`。
- current/transition 角色投影与静态 warm 策略：`pipeline`。
- texture/frame 实际预算与回收：`sessions`/`pipeline_runtime`。
- Reader Widget 仅保留轻量 host，不建立重资源缓存。

## 拒绝方案

- 继续使用中心点或 50% 阈值：真实可见页会处于无 demand 的伪 loading。
- 为所有静态章节固定保留更多页：不同分辨率和设备内存下不可控。
- 让 ListView host 自己保存 decoded image/texture：会与 Pipeline output 生命周期竞争。
- 把静态页套用动画多帧水位：浪费 decoded-frame 内存，且不能表达更多页面的一帧保留。

## 解除 Provisional 条件

设备 Trace 证明：纵向相邻页进入视口即出现 transition demand；static warm decode/upload 数量随图片尺寸和预算变化；已挂载可见宿主不再长时间无首帧；FrameBudget 超限时按优先级回收，且动画 staged 水位不受影响。
