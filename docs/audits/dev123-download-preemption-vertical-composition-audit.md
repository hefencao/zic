# dev.123 下载抢占与纵向页面合成审计

## 基线与参考

- 唯一代码基线：`zic_v0.31.0-dev.122_retained-transfer-partial-prefix-playback.zip`。
- 只读参考：Library 中的 `vibevenera-master(4).zip`。
- 本轮不修改 Mihon、VibeVenera 或 libwebp 参考源码。

## 问题清单

### 编译错误

- 当前静态结构检查尚未发现本任务直接引入的编译错误；完整 Flutter analyzer 仍待工具链验证。

### 产品错误

1. `NetLane` 只对 queued task 排序；同一页面从 next/near 晋升 current 时，active task 的 priority 不更新。
2. 网络槽满时，新 current 只能继续排队，无法立即获得下载执行机会。
3. 离开窗口但仍 active 的 retained transfer 与新 current 共用槽位，却没有有界 handoff；保留策略因此可反向饿死 current。
4. 纵向 Reader 的 `itemBuilder` 每次 lazy build 都重新组合 `RotatedBox → Zoomable → Host → pageBuilder`；滚动过程中 child 新建与布局成本仍高。
5. 纵向 extent 虽由 `itemExtentBuilder` 提供，但 geometry/extent 与 page shell 仍在 build 路径重复计算，没有稳定的预组合页面槽和布局快照。

### 性能问题

1. current 提权不触发重新派发，首字节延迟取决于旧 active transfer 的自然完成时间。
2. 页面切换后运行中任务 rank 陈旧，后续抢占候选与 trace priority 不可信。
3. 纵向滑动时新进入 cache extent 的页面需要现建交互/旋转/host 子树；低性能设备 build+layout 可形成明显掉帧。
4. `ReaderVerticalGeometry.boundsAt/positionAt/visibleCoverages` 多次线性扫描；长章节在滚动 observation 与命令处理中会重复计算前缀位置。

### 测试错误

- 现有 `net_lane_test.dart` 只覆盖 queued priority、FIFO 和并发上限，没有覆盖 active rank migration、current handoff、同 key 不重建和有界超额槽。
- Reader 测试没有覆盖“预组合页面 Widget identity 不因滚动 builder 重复创建”及 geometry 前缀快照复用。

## 所有权清单

| 状态/资源/命令 | 当前所有者 | 正确所有者 | 本轮处理 |
|---|---|---|---|
| queued/active 网络任务 | `sessions/NetLane` | `sessions/NetLane` | 保持；补 active priority 与 handoff |
| 页面下载 rank | `pipeline` 生成、`pipeline_runtime` 提交 | 同左 | 保持；每次 plan revision 迁移到 lane |
| active transfer retained | `sessions/LiveCoordinator` | `sessions` | 保持；不因离窗直接取消 |
| current 抢占/临时 handoff | 当前缺失 | `sessions/NetLane` | 新增通用 lane 原语 |
| 7/3 页面窗口 | `pipeline` | `pipeline` | 不变 |
| 纵向页面几何 | `reader/ReaderVerticalGeometry` | `reader` | 改为不可变 extent/prefix 快照 |
| 页面 Widget composition | `reader/ReaderView` | `reader` | 预创建稳定 page shell 列表 |
| 图片字节、frame、texture | `downloads/sessions/pipeline` | 同左 | Reader 不新增缓存 |
| 当前页/滚动 observation | `reader/ReaderController` | 同左 | 不变 |

## 被否决方案清单

1. **缩小 7/3 窗口、降低远程并发或关闭 retained transfer**：掩盖调度缺陷，并导致重新下载。
2. **current 到来时取消并重建同 key 下载**：会让同一 DownloadSession 出现竞争 writer，丢失已下载字节。
3. **Reader 内建立图片字节 LRU 或 decoded frame 私有缓存**：违反统一缓存和 Pipeline 所有权。
4. **用 visible 页强制 demand 代替预下载/预解码**：此前已证明只是进入视口后的补救，不能解决预加载。
5. **预创建整章真实 Image/Texture**：内存不可控；本轮只预组合轻量 Widget slot，重资源仍按 Pipeline/FrameBudget。
6. **复制 VibeVenera 的私有 ImageStream LRU**：其所有权模型与 ZIC 不同，只参考稳定 item、keep-alive 和调度语义。
7. **用固定 pump、文本匹配或删除失败测试通过验证**：禁止。

## 初步决策

- 在 `NetLane` 增加 active rank migration、current 高优先级阈值、一个有界 handoff slot；同 key active 只更新 rank，不取消重建。
- current 进入满载 lane 时，优先请求取消最低 rank 且可抢占任务；retained/non-preemptible transfer 可继续，但 current 仍可使用唯一 handoff slot立即启动。
- handoff 不改变稳定并发上限，最多临时 `maxActive + 1`，任一任务完成后恢复。
- 离开窗口但仍 active 的 retained transfer 继续完成，但 rank 降为后台 0。
- Reader 预创建稳定 page shell Widget 列表和 extent/prefix 快照；ListView 仍 lazy mount，不预创建图片资源。
