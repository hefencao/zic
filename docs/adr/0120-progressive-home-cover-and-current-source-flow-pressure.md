# ADR 0120：首页主投影提前发布与 Current Source 流量压力

**状态：Accepted in dev.137**

## 背景

设备 Trace 显示首页服务约 54 ms ready，但第一条封面请求约 1.88 s 才发出；封面缓存命中和首帧本身仅需数十毫秒。远程 Reader 中，约 16–20 MiB 页面可产生一万余个约 1.4 KiB transport chunk，每个 chunk 都触发 artifact/native/source-revision 链。current WebP producer 缺数据时，同源背景预下载继续制造细碎工作。

## 决策

- `HomeLibrarySession` 将可产生封面的 primary projection 与 enrichment 分离。章节列表和 SavedComic 并行读取并立即发布；分类、偏好、源偏好、阅读状态和缺失默认值补写在后续阶段完成。
- `DownloadJob` 物理合并普通响应：首批 16 KiB，之后 64 KiB；partial/resume 保留。
- `LiveCoordinator` 拥有一个 cooperative `DownloadFlowGate`。current 远程 producer 启动、waitingSource 或 decode depth ≤1 时，同 source bucket 背景任务在读取下一 transport chunk 前等待；depth ≥3、source 封缄、静态 output、切页或失败终止后释放。
- 背景任务仍在原 NetLane、原 demand 和原 7/3 窗口内，不取消、不重开。
- Trace 新增 `downloadFlowPressure`，首页分析新增 primary/enrichment 与 first cover request 时间。

## 边界

- 流控只在 sessions 内部作用于 transport consumption，不进入 Reader、App UI、插件或网络实现。
- 不改变 `ReaderPipelineProfile.stable` 的 7/3、5/3/2 和 remote bucket 5。
- 不改变 native ABI、texture、decode worker 数量或 WebP duration。
