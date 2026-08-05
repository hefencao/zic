# ADR 0120：首页主投影提前发布与 Current Source 流量压力

**状态：Partially superseded by ADR 0121 in dev.138**

## 背景

设备 Trace 显示首页服务约 54 ms ready，但第一条封面请求约 1.88 s 才发出；封面缓存命中和首帧本身仅需数十毫秒。远程 Reader 中，约 16–20 MiB 页面可产生一万余个约 1.4 KiB transport chunk，每个 chunk 都触发 artifact/native/source-revision 链。current WebP producer 缺数据时，同源背景预下载继续制造细碎工作。

## 决策

- `HomeLibrarySession` 将可产生封面的 primary projection 与 enrichment 分离。章节列表和 SavedComic 并行读取并立即发布；分类、偏好、源偏好、阅读状态和缺失默认值补写在后续阶段完成。
- `DownloadJob` 物理合并普通响应：首批 16 KiB，之后 64 KiB；partial/resume 保留。
- dev.137 曾加入 `DownloadFlowGate` 和 `downloadFlowPressure`；该全局网络资格门控已由 ADR 0121/dev.138 删除，因为它阻塞 transition 页首帧。
- 首页分析保留 primary/enrichment 与 first cover request 时间。

## 边界

- 不改变 `ReaderPipelineProfile.stable` 的 7/3、5/3/2 和 remote bucket 5。
- 不改变 native ABI、texture、decode worker 数量或 WebP duration。
