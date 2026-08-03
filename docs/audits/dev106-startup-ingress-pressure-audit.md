# dev.106 启动 ingress 压力审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.105_direct-promoted-artifact-hot-cache.zip`
- 设备 Trace：`zic-debug-trace-2026-08-03T12-45-25.jsonl`
- 参考：VibeVenera 修改后的 local file loader 与 encoded-byte cache，仅用于读取/缓存链对照。

## 设备事实

Trace 包含 207 条 `framePipelineTiming` 和 44 条 `sourceRead`。三个 foreground `read-all` 的 `artifactMaterializeMicros` 约为 23.9 ms、3.3 ms 和 11.5 ms，说明 dev.105 的 isolate 整文件读取不是当前秒级主因。

完整 response stream 的 p50 约 846 ms、p95 约 2.20 s；该字段包含 Reader DownloadSession 临时 artifact 写入、native ingress 和下游 backpressure，不等同于纯读盘。首个 Reader mount-to-first-frame 约 2.15 s。启动时 current 之外已有多个 background persistent streams，且 current materialize 完成后 foreground lease 已释放。

首帧 `outputPrepare` 约 565 ms，前两次 platform presentation 约 243 ms；这些长尾发生在 background session-copy 同时灌入期间。Flutter build/layout/paint/raster 低与该链路一致。

## 所有权结论

| 问题 | 所有者 | 处理 |
|---|---|---|
| materialize 后提前释放 foreground lease | `downloads` | lease 延长到 body drain/discard |
| 内存 bytes 再按 1 MiB response chunks 循环 | `downloads` | foreground whole-body delivery |
| 首帧形成前 background 已同步抢槽 | `pipeline_runtime` → `downloads` pressure projection | `binding.accept()` 前建立 pressure hold |
| background 公平性 | `downloads` | 保留 dev.104 chunk quantum，不取消 active 工作 |
| pressure 释放条件 | `pipeline_runtime` + `sessions` snapshots | 已呈现且 successor depth≥2，或权威静态/结束/失败 |

## 拒绝方案

- 不缩小 7/3 或 2/1 窗口掩盖拥堵。
- 不把 encoded bytes 或 scheduler 放进 Reader widget。
- 不把 Trace `streamMicros` 重新解释成纯磁盘耗时。
- 不取消 background active stream 或在角色晋升时重开文件。
- 本轮不引入第二套 ingress-only DownloadSession；先验证前景压力和 chunk/wakeup 消除是否足够。
