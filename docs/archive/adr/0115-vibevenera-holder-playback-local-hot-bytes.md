# ADR 0115：VibeVenera Holder 驱动播放与本地热字节

**状态：Superseded**

## 问题

dev.131 设备 Trace 仍有 431 次 startup decode defer、6 次播放中 rebuffer，以及长后台后 1.4–2.0 秒首帧。连续修补 startup buffer、source wake 与 role 生命周期没有消除问题，反而让一个页面的播放状态成为全局 decode eligibility 条件。

## 参考

只读检查 VibeVenera 的 `StreamingImageCompleter`、`WebPDecodeSession`、`WebPFrameHolder`、native worker queue 与 `ByteCache`：

- 播放器只消费 holder 中已经存在的帧；缺帧时保留当前画面并等待 producer signal。
- decode producer 按 demand 持续补帧，current worker 请求可批量返回两帧。
- 最近完整页面字节可在进程级有界缓存中复用；可见组件不拥有正文缓存。

## 决策

1. 删除 startup-buffer 状态、current-only decode gate、`decode-startup-deferred` 和 upload snapshot 定向补水特例。
2. 首帧仍立即呈现。帧截止后若 successor 尚未到达，当前 output 保持可见；新 frame 进入 holder 后沿既有 snapshot/wake 链恢复 upload。
3. NativeCursor 首次请求一帧；已有元数据后的 current 请求最多两帧。批次中未消费 frame 由 cursor 有界持有，rewind/dispose 时释放。
4. 完整读取的本地不可变 origin（content/file/asset）在流正常结束且长度吻合后，写入 composition-owned `ArtifactCacheManager` 内存 LRU。取消、失败、范围请求和不完整流不得缓存。
5. 不建立 Reader/App 私有 LRU，不跨 Reader 复用 used texture，不增加 native worker。

## 所有权

- holder 消费与播放 deadline：`sessions/UploadSession`。
- 全局 refill/source revision：`sessions/LiveCoordinator`，不读取播放缓冲状态。
- native 批次与未消费 frame：`bridge/NativeCursor`、`_NativeDecodeWorkerPool`。
- 页面热字节：composition-owned `downloads/ArtifactCacheManager`。

## 保持不变

- 下载窗口 7/3、staged 水位 7/5/3/2、静态单帧满足。
- 两个 native worker、current priority migration、partial source-growth。
- fresh Reader texture 生命周期与 Android native ABI。

## 解除 Provisional 条件

设备 Trace 证明：长后台重入同一页面命中 `artifact-byte-cache`；新运行时不产生 startup defer/rebuffer；current 双帧批量请求没有泄漏 native frame；播放饥饿期间保持当前画面并在 producer 到帧后连续恢复。
