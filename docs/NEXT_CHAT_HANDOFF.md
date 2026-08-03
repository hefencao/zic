# dev.96 后续交接

本轮验证明细：`docs/audits/dev96-validation-results.md`。

唯一后续基线：`zic_v0.31.0-dev.96_local-webp-resident-single-thread-playback.zip`。不得混入 dev.95 或更早候选。

## 已完成

- bridge 双 decode isolate 由 App composition 在 `runApp` 前显式等待预热完成并进程期常驻，current 保留槽，cursor 不拥有 pool 关闭。
- ScheduledFrameCursor 只把 session 的 PageRole 调度意图下传；Reader/App 未获得 native 能力。
- transition→current same-key decode/upload 使用 follow；current successor 水位 2。
- libwebp 1.6.0 自动补丁链、VP8 TLS workspace、帧内单线程；明确禁止额外 persistent native worker pool。
- 预乘 RGBA 在 media_core 唯一生成；Android 不重复 geometry/alpha，Flutter fallback 不二次预乘。
- metadata 主动刷新、小尺寸不放大、本地 1 MiB 分块；网络 256 KiB 和既定窗口/lane 不变。

## 下一步设备验证

1. 在能访问上游且装有 Rust/CMake 的环境运行 `tool/prepare_webp.sh`、`tool/check_webp.sh` 和 `cargo test -p media_core`，确认补丁在精确 v1.6.0 tree 应用。
2. 运行 Flutter analyze 与受影响 package/App tests，再构建 Android debug/release。
3. 真机记录首次进入、退出重进、transition→current 连续滑动、透明动画和长播放 trace；重点比较 worker 冷启动、decode dispatch、successor depth、texture create/retire、firstFrameReady。
4. 不得通过缩小 7/3、2/1 或 5/3/2 掩盖问题；未取得数据前不改这些参数。

# 下一聊天交接

dev.95 是本轮 dev.96 的历史输入基线；后续不得再以它覆盖顶部列出的 dev.96 唯一基线。

## 已完成

- 保留 dev.92–94 的静态/有限动画、successor、direct-fd、常驻 decode worker 与持久 demux 修复。
- promoted artifact 支持范围流并直接进入唯一 DownloadSession；流式 cache 禁止 read pool 再物化完整页面。
- Artifact 使用 IOSink 缓冲写；DownloadSession 对 artifact/native ingress 复用同一 owned chunk。
- native ABI 6 增加 expected-capacity、reserve/commit；Dart 直接写 native source 预留区，只有 committed prefix 对 decoder 可见。
- demux 在 descriptor 已覆盖下一帧时复用；partial 缺帧时按 512 KiB 或 seal 受控刷新。
- ANMF rectangle 使用共享 source endpoint 映射，libwebp 直接缩放到 target rectangle，并在 target canvas blend/dispose；删除 source-size canvas 与完整二次缩放。
- 旧 dev.82 禁止独立 round(offset)+round(width) 的原则继续有效；当前目标画布实现依靠公共端点映射保证相邻 rectangle 无缝。
- 新增 cache stream、artifact range、native ABI、target rectangle 与 dev.95 所有权门禁。

## 设备复验重点

1. 对同一个已缓存大 WebP 比较 dev.94/dev.95 的 `sourceRead`、首次 `bytesCommitted`、`frameDecoded` 和 `firstFrameReady`。
2. 确认 cache 命中没有第二次整页 read/prime，`nativeIngressMicros` 与 `artifactWriteMicros` 不再形成秒级 UI/platform callback 阻塞。
3. 检查首帧是否接近 VibeVenera 的 200 ms 级表现；未取得 Trace 前不得假定已经达标。
4. 检查相邻条带、奇数尺寸 frame rect、alpha blend、dispose、有限循环、回切和末帧保留。
5. 若 native decode 仍慢，下一步分析 target canvas clone/native frame ownership；不得再缩小 7/3、2/1 或增加 Reader 私有缓存。
6. 部分远程图片无法下载仍是独立后续项。

## 约束

Reader/App 不得新增帧、字节、artifact path 或 texture cache。promoted cache/file 属于 downloads/storage；活跃 source 属于 DownloadSession/Ingress；native reservation 属于 bridge/media_core；demux/canvas 属于 media_core；UploadSession/texture_bridge 继续唯一拥有 renderer output。保留 7/3、2/1、current/transition、5/3/2、256 KiB 与 GET/HEAD 零 body。
