# dev.133 修改前审计

## 编译问题

- 当前未收到新的编译错误；本轮必须保持 dev.132 编译闭包，不恢复已删除的 retained output 类型。

## 产品问题

- 退出 Reader、切后台、重新进入同一大 WebP 后仍卡顿。
- 动画进入 Reader 后仍会出现连续播放几帧、长停顿、再继续。

## 性能证据

- 新 Trace 的 `pipeline-reader-5` 在长后台后重新进入 page 15，当前页仍从 `content://` origin 重读 18,319,682 bytes，`streamMicros=3,359,779`，首帧 2,260,511 us。
- `pipeline-reader-6` 已命中 `artifact-byte-cache`，但仍被分成 18 个 1 MiB chunk 回放进新 DownloadSession/native ingress，`streamMicros=970,861`，首帧仍为 930,133 us。
- dev.132 热缓存只有 4 项，而同一章节下载窗口为 7/3；当前页字节可被邻页完成顺序淘汰。VibeVenera `ByteCache` 默认保留 10 项。
- 后台后的动画 `present` 仍有 200 ms–1.5 s 长尾；ZIC texture bridge 使用 background MethodChannel task queue、两个 blit lane、主线程 `postAtFrontOfQueue` 和跨线程 completion。VibeVenera 使用默认 platform-channel 线程、单一串行 blit executor、普通 `mainHandler.post` 后直接 `scheduleFrame` 并完成调用。

## 所有权

- 页面热字节继续由 composition-owned `ArtifactCacheManager` 管理；Reader/App 不增加私有缓存。
- DownloadSession 仍是 artifact、partial 和 ingress 的权威所有者。
- Android texture 创建、blit、schedule、release 继续由 `texture_bridge` 管理。
- 播放 deadline、FrameHolder、DecodeSession 和 7/5/3/2 水位不在本轮修改。

## 本轮拟修改

1. 将热字节 LRU 默认改为 VibeVenera 同级的 10 项，并设置 192 MiB 总上限，避免 7/3 窗口完成顺序淘汰当前页。
2. current 的 memory-hit 不再使用 1 MiB `startup-segmented` 回放；以一个 `Uint8List` chunk 直接交给 DownloadSession/native ingress，仍只进行一次权威 append/seal。
3. Android texture bridge 改为 VibeVenera 的单串行 blit + platform main channel/schedule 模型，删除 background task queue、双 blit lane 和 `postAtFrontOfQueue`。
4. 保留 ZIC 现有 timing response、native frame retain/release 和 fresh Reader texture 生命周期。

## 否决方案

- 不继续新增 startup buffer、current-only gate 或播放 rebuffer 状态。
- 不跨 Reader 复用已使用 texture。
- 不缩小 7/3 或 7/5/3/2。
- 不增加 decode worker。
- 不在 Reader 中建立 ByteCache、FrameCache 或 GPU cache。
- 不通过降低画质、跳帧或隐藏 loading 掩盖长尾。

## 补充 Trace 证据

- `workerPlacementStatus=3` 出现 80 次，说明 dev.129 的 affinity 在该设备被系统拒绝；VibeVenera 使用实际 TID，并在设置 affinity 后 best-effort 请求更高线程优先级。
- dev.133 将高性能 mask 与当前 Android cpuset 求交后，再对实际 TID 调用 `sched_setaffinity`，避免被 vendor/EAS cpuset 排除的核心导致 `EINVAL`。
