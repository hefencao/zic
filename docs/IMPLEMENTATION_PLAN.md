# zic Implementation Plan

本文件只列未完成工作。

## P0：资源会话后台重入设备闭环

- 同一 chapter/source revision 退出 Reader 后应记录 `readerSessionRetained`；2 分钟内重入应记录 `readerSessionReused`，且不出现新的 `readerSessionCreated`。
- retained 重入时不应再次出现 current 18.3 MiB `memory-direct` ingress、整组 7/3 `downloadStarted` 或新的 native source/cursor 构造。
- used texture 必须随旧 Reader output 释放；重入仍创建 fresh SurfaceProducer，不能恢复旧 texture。
- 检查 long-background 首帧和前 15 帧的 source/decode/present 分段；CPU affinity 已删除，不再以 `workerPlacementStatus` 推断瓶颈。
- 超过 2 分钟、切换另一章节或 source revision 变化时，应完整 dispose retained 会话并正常冷启动。
- 对照 VibeVenera 验证资源会话保留后，首帧和连续播放仍不达标的剩余差异；不得再增加 Reader 私有缓存或并行 scheduler。

## P0：资源与 partial 回归

- 确认 retained session 在 demand 归零时不会继续上传或持有 used texture。
- 确认 active transfer、artifact promotion、partial source-growth 和 native priority migration 在 idle/reuse 边界保持同一权威状态。
- 确认 TTL/容量淘汰只 dispose idle session，不影响 active leased Reader。

## P1：纵向 build/layout

继续用设备 Timeline 验证稳定 page composition 与渐进 host warm 的实际收益。
