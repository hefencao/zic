# ADR 0102：本地不可变资源直连与全部可见页输出所有权

**状态：部分被 ADR 0103 取代**

## 背景

设备 Trace 显示两个独立问题：

1. `content://` 本地大 WebP 在跳页后仍走普通 staged download：最多 5 个 16–20 MiB 文件并发分块读取，同时写 Reader 临时 artifact。单个约 5.5 MiB 文件可在约 0.12 秒完成；并发后 14–19 MiB 文件上升到约 3.5–4.3 秒。UI 还把该本地复制显示为下载进度。
2. 纵向视口可同时露出多页，但 Reader observation 只表达 current 与一个 target。其他仍可见静态页作为推测性 warm output，在角色切换时以 `demand-detached` 释放，反向滑动时重新出现 loading。

## 后续状态

本地不可变资源直连、local bucket=2 与本地进度投影继续有效。`PageRole.visible`、全部可见页强制 demand 和可见 output 特殊保护已被 ADR 0103 取代；根因应由预加载 source wake 与静态 output 驻留解决。

## 决策

### 本地资源

- `file`、`content`、`asset` 的完整只读响应标记为 `durableImmutable`。
- 它们继续由权威 `DownloadSession` 管理 ingress、seal、epoch、demand 与 dispose，但不写 Reader 临时 artifact。
- 本地来源 bucket 并发先设为 2；远程 source bucket 与全局并发仍为 5。
- 本地读取不投影为下载进度。
- presentation 需要原始 bytes 且没有 cache/artifact 时，从同一不可变来源按 validators 重新读取，不建立第二个 writer。

### 纵向可见页

- `ReaderObs` 携带视口内全部真实可见覆盖。
- Pipeline 增加 `visible` 角色；current、primary transition、last 与其他可见页保持独立优先级。
- 已知或推断静态的 visible 页获得一帧 decode/upload；额外可见动画页不获得推测性多帧 refill。
- FrameBudget 保护所有实际可见 output。即使受保护 output 总量超过预算，也不得将仍可见区域变黑。
- 96 MiB 静态预热选择改为按页面元数据估算实际 RGBA 占用；全部可见页先选入，剩余预算才用于视口外邻页。

## 未采用

- 仅隐藏本地进度条：不能消除 5 路 SAF 读取与临时 artifact 写入。
- 缩小 7/3 窗口：会回退既定预取行为，且不解决来源级并发。
- 只继续增加 ListView `cacheExtent`：轻量 host 已保活，当前缺口是 Pipeline output demand。
- 固定增加静态保留页数：不同分辨率下内存占用差异过大。
- 在 Widget 层缓存图片或 texture：会建立第二套资源所有权。

## 验收

设备 Trace 应满足：

- 本地 origin 页面 `artifactWriteMicros=0`，local bucket active 不超过 2；
- 本地 current 不再出现网络式 transfer progress；
- `readerObservation.visibleIndexes` 包含全部视口交叠页；
- `policyDecision.visibleUploads` 与实际额外可见页对应；
- 可见页不再出现由普通角色切换引起的 `pageOutputReleased reason=demand-detached`；
- 视口外静态预热仍受 96 MiB 选择和 128 MiB FrameBudget 控制。
