# ADR 0121：VibeVenera 独立目标页传输与 Transition 首帧

**状态：Accepted in dev.138**

## 问题

dev.137 为保护 current 远程动画增加了同 source bucket 的 `DownloadFlowGate`。当 current source 未封缄且 decode depth 不高于 1 时，所有同源非 current 任务在读取下一 transport chunk 前等待；只有 current depth 达到 3 才释放。

该全局门控把 current 播放状态变成了目标页网络资格条件。用户设备出现进入 Reader 后必须等第一张图片完整下载或 current 补足后才能切页。与此同时，`StagedDecodeRefillPolicy` 仍固定先执行 `c>2`，transition 首帧只能随后执行 `n>1`，形成网络与解码两层串行门槛。

## VibeVenera 参考

只读架构文档规定：

- 当前页必须优先，但切页不能被邻页工作阻塞；
- transition 在中点之前建立，并保留独立首帧需求；
- current 水位不足时，只延后 transition 的深入预解码，不能取消或阻塞其首帧；
- download、decode、upload 使用独立 lane；一个 decode worker 可补 current，另一个可准备 transition；
- 已经 receiving 的下载不会因为窗口变化被主动断开。

## 决策

1. 删除 `DownloadFlowGate`、`DownloadChunkPermit`、`beforeReadChunk`、`downloadFlowPressure` 及 LiveCoordinator 中全部 hold/release 逻辑。
2. Current 网络优先只由已有 `NetLane` 保留槽、priority migration 和 preemption 负责；它不能冻结目标页连接。
3. transition depth 为 0 时，`StagedDecodeRefillPolicy` 先返回独立 `t>0`，目标仅为一帧；该决定发生在 `c>2` 之前。
4. transition 已有一帧后，继续使用既有 staged 顺序：先补 current 到 3，再逐步加深 transition 和邻页。
5. 保留 target coverage 0.15 的早期 transition promotion、7/3 encoded window、7/5/3/2 水位和 5/3/2 lanes。
6. 保留 dev.137 的首页分阶段发布和小 transport chunk 合并；它们不再携带网络资格门控。

## 后果

- 用户拖动后，目标页网络和首帧解码不再等待 current 完整下载或 depth 3。
- current 仍有全局高优先级保留槽，可抢占较低优先级任务。
- transition 深入预解码仍在 current 基础水位之后，不会让目标页反向饿死 current。
- 不建立 Reader 私有下载或解码路径。

## 取代关系

本 ADR 取代 ADR 0120 中的 Current source flow-pressure 决策；ADR 0120 的首页 primary/enrichment 发布与 transport chunk 合并继续有效。
