# dev.133 VibeVenera 后台重入直接字节与单 Blit 审计

## 输入证据

- 唯一代码基线：`zic_v0.31.0-dev.132_vibevenera-holder-playback-local-hot-bytes.zip`。
- 设备日志：`zic-debug-trace-2026-08-05T02-01-59.jsonl`。
- 只读参考：VibeVenera `ByteCache` 与 Android `WebPTexturePlugin.kt`。

## Trace 结论

- Reader 5 长后台重入 current 页面未命中热缓存，重新读取 `18,319,682` 字节 `content://`，`streamMicros=3,359,779`，首帧 `2,260,511 us`。
- Reader 6 命中 `artifact-byte-cache`，但仍以 18 个 1 MiB chunk 回放，`streamMicros=970,861`，首帧 `930,133 us`。
- 热缓存当时只有 4 项、约 73 MiB；7/3 下载窗口足以把较早 current 页面淘汰。VibeVenera `ByteCache` 默认 10 项。
- `framePipelineTiming` 中 platform present 最大 `1,537,225 us`，多帧 `platformScheduleQueue` 超过 100 ms。ZIC 仍为 background MethodChannel、双 blit lane 与 `postAtFrontOfQueue`，与 VibeVenera 单 lane/main channel 不同。
- 80 个 frame 的 `workerPlacementStatus` 全为 3；旧 affinity 在该设备未生效。

## 实现决策

1. ArtifactCacheManager 默认 10 项/256 MiB，完整本地不可变 origin 标记为进程内 durable immutable。
2. current memory hit 使用单个 `Uint8List` body；不再进行 1 MiB cooperative replay。持久 artifact 首次 materialize 仍使用 startup segmented，防止冷缓存 read-all 在一个 event-loop turn 内占用过长。
3. Android texture 改为默认 platform MethodChannel、一个串行 blit lane、普通主线程 `post`；MethodChannel result 从 blit 线程统一投递回主线程。
4. decode affinity 使用实际 TID，并先与当前 cpuset 求交；成功后 best-effort 请求 VibeVenera 同款 `nice=-10`。
5. native library identity 更新为 `zic-media-core-dev133-abi6-lib00121300`。

## 所有权审查

- Reader/App 未新增 byte cache。
- `downloads` 仍是热字节唯一所有者；`sessions` 仍是 DownloadSession/native ingress 所有者。
- Android `texture_bridge` 仍是 SurfaceProducer/blit 唯一所有者。
- worker 数量仍为 2，水位与下载窗口未修改。
- 不恢复 used texture 跨 Reader 复用。

## 风险

- 10 项/256 MiB 提高了进程内 encoded byte 上限；仍为严格 LRU 且只缓存完整不可变本地资源。
- 单个 18–20 MiB body 会在一次 native ingress 调用中复制；设备验证应确认其耗时低于旧 18 段约 971 ms，并检查 Dart isolate 没有新的长停顿。
- Android Rust affinity 需要真实 NDK/Cargo 构建和目标设备 Trace；当前环境不能验证 `gettid`/cpuset 路径。
