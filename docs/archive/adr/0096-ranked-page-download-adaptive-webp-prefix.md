# ADR 0096：全局页面下载排序与自适应 WebP 解码前缀

**状态：Provisional**

## 问题

dev.111 设备 Trace 显示，startup priority floor 只约束 persistent-artifact 的内层 chunk 调度，没有解决跨 Reader、跨多页跳转的页面任务总并发和排序：旧窗口与新窗口可同时保留多条任务，far 页面又共享 priority 400。累计 scheduler wait p95 超过 5 秒，整体加载反而恶化。

同一 Trace 有 14 次 decode failure。多数失败发生在完整、已封缄的 WebP 上，不能解释为 chunk 不足；少数 partial source 需要避免每个小增长都重复尝试解码。

## 决策

1. `PipelineReaderSessionFactory` 持有 composition 级共享 `NetLane`，所有 Reader 页面传输全局最多同时 5 个。单个 Reader dispose 只取消并等待自己的 task key。
2. 7/3 demand 不变；每个窗口页按 current、transition、距离和方向获得唯一 rank。跨页跳转时退出窗口的 queued/active task 被取消，新窗口按新 rank 入队。
3. 页面传输按 bucket 施加来源上限：local/content/asset 共用本地 bucket；远程按 `sourceId` 分 bucket。当前本地与每个远程来源上限均为 5，保留由来源能力降低的入口。
4. 删除 startup background priority floor。startup artifact pressure 只保留通用 foreground/background 保护，并在 current output 已呈现且 `c>4` 后释放。
5. 增加 composition 级 `WebpDecodePrefixHints`，按 `DownloadId + frameIndex` 学习 partial WebP 的最小尝试前缀。本地每次增加 1 MiB，远程每次增加 256 KiB；只有 cursor 返回 `needMoreData` 且 source 未封缄时增长。
6. 成功的 partial decode 记录最小已观察到的充分前缀；sealed source success/failure 不参与前缀学习。完整文件失败继续使用有界 cursor recovery，并在 Trace 中标记 `sealed-source`，不能用增大 chunk 掩盖。

## 所有权

- 页面任务 rank 和窗口语义属于 `pipeline`。
- composition 级总并发、来源 bucket 与 factory clone identity 属于 `pipeline_runtime`。
- 通用 lane、DecodeSession、partial-prefix hint 与 cursor recovery 属于 `sessions`。
- artifact chunk 公平调度仍属于 `downloads`，但不再决定页面 rank。

## 拒绝方案

- 用 startup priority floor 代替页面任务全局并发和 rank。
- 缩小 7/3 窗口来减少任务数。
- 所有 decode failure 都增加 chunk；sealed malformed、cursor 状态或 native decode 错误不会因此修复。
- 每个 Reader 各建一条 5 槽网络 lane；快速重进会再次形成 10 个并发任务。

## 解除 Provisional 条件

设备 Trace 证明 `downloadStarted.globalActive<=5`；不同页面按唯一 priority 启动；快速跨页后旧窗口任务停止；startup pressure 在 `c>4` 释放；partial source 出现 `decode-prefix` 阶梯并在充分前缀后成功；sealed-source failure 不进入无限 chunk 增长。
