# ADR 0109：后台恢复保留输出与 Partial Source Growth

**状态：Provisional**

> 跨 Reader retained platform output 的决策已由 ADR 0113 取代并删除；本 ADR 的 partial source-growth 与 sealed failure 边界继续有效。

## 问题

dev.124 设备 Trace 中，首次进入 Reader 的首帧通常约 0.23–0.39 秒；切后台约 15 秒后重新进入，同一页面首帧升至约 1.19–1.20 秒。精确 output prewarm 仍命中，恢复后的 `surfaceReconfigureCount=0`，但 source wait、native decode 和 platform present 同时重新进入慢路径。进程级 Android texture pool 已保留 lease 与最后 native frame，新的 Reader session 却只能按尺寸复用 lease，不能按 DecodeId 恢复已有画面。

未封缄 partial source 的 native decode `failed` 也不能视为确定性损坏。若它进入 16/32/48/64 ms 定时恢复，会销毁 cursor、清空可用帧并与 source growth 竞争。

## 决策

1. `FrameUploader` 可选实现 `RetainedOutputUploader`，只按完整 `DecodeId` 恢复进程内最后 platform output。
2. Android texture pool 的 idle lease 可携带最多 64 MiB 的 retained frame 元数据；恢复只匹配同一 DecodeId，不按尺寸猜测。
3. 恢复 output 是 Presentation 状态，不是 decoded-frame 或 artifact 权威。正常 download/decode 继续，后续 authoritative upload 原子替换它。
4. 新 Reader 先 redraw retained texture，并通过现有 `PipelinePageSurface` 投影；不复制图片字节、不创建 Widget LRU。
5. NativeCursor 对未封缄 source 的 ABI `failed` 归一为 `NeedMoreData`；只有 sealed source 才抛出 decode failure。
6. LiveCoordinator 对未封缄失败只等待新的 source revision，不进入定时 decode recovery；sealed current/transition 仍使用原有有界恢复。
7. `.zic-workspace.json` 为机器本地配置，加入 `.gitignore`，不得进入发行 ZIP 或 patch。patch 工具优先读取 `ZIC_PATCH_DIR`，其次读取本地配置。

## 所有权

- retained platform frame 与 lease：`pipeline_native` / `texture_bridge`。
- restore 投影和替换：`sessions/UploadSession`。
- source sealed 与 partial recovery：`bridge`、`sessions`。
- patch 目录：本地 workspace/tooling，不属于发行源码状态。

## 拒绝方案

- 不把 texture 当解码缓存或跳过后台 authoritative decode。
- 不按相同尺寸恢复其他页面。
- 不在未封缄失败后定时重建 cursor。
- 不依赖 VibeVenera 的无条件循环语义。
- 不把远程机器的 patch_dir 写入用户发行包。

## 解除 Provisional 条件

Flutter/Android 构建通过；后台恢复 Trace 出现 `retainedOutputRestoreCount>0`，恢复首屏不再等待 source/decode；partial source failure 只出现 `decode-source-growth`，sealed corruption 仍进入有界 recovery。
