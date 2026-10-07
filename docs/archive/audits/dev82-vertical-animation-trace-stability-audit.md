# dev.82 纵向动画、播放推进与 Trace 稳定性审计

## 问题清单

### 编译/测试错误

- `packages/downloads/test/source_resource_transport_test.dart` 三个“可控响应”测试仍在 30 秒超时。测试 helper 在 `StreamIterator` 暂停订阅时等待 `StreamController.close()`，形成确定性关闭死锁，不是产品 socket 超时。
- `packages/reader/test/vertical_reader_geometry_test.dart` 对二进制浮点数使用精确相等，`319.99999999999994` 与 `320.0` 被错误判为产品回归。

### 产品错误

- 纵向布局中的动画 WebP 出现横向条带错位。截图显示单页内容内部被拆成多条水平带并发生位移，不能用页面间距、负位移或重叠修复；应检查动画增量合成和平台纹理帧的权威内容。
- 动画播放在下载过程中可推进若干帧，随后停滞。Trace 显示 source 持续增长时 decode 被反复唤醒，但下载完成后 frame consume 没有独立于 source revision 的 decode 唤醒。
- `bytesCommitted`、`decodeStarted`、`uploadStarted` 高频事件短时间内超过三万条，raw ring 很快截断为最后两万条，既扩大导出文件又丢失问题前因。

### 性能问题

- source 每个小 chunk 都触发所有关联 decode demand；即使 holder 已满，也记录 `decodeStarted` 并继续触发无效 upload。
- Trace 中单页约两千次 decode/upload started 只产生约五十帧，调度与诊断开销远高于有效工作。
- 每个网络小 chunk 独立记录 `bytesCommitted`，缺少生产侧批量摘要。

### 测试错误

- 不得再用真实 socket、固定等待、暂停订阅后等待 close、lazy child 数量或精确浮点相等证明流式/几何行为。
- 动画推进应使用可控 cursor、可控 frame holder 和显式 source revision；合成应使用确定性 sub-rect/dispose/blend fixture。

## 所有权清单

| 状态/资源/命令 | 当前所有者 | 正确所有者 | 处理 |
|---|---|---|---|
| source 增长 revision | `DownloadSession`/`LiveCoordinator` | 同左 | 保留，但只用于解除 `needMoreData`，不得替代 frame-consumed wake |
| holder 消费后的下一帧 decode | 间接依赖下一次 source 增长 | `LiveCoordinator` + `DecodeRegistry` | 新增强制 frame-consumed decode 路径 |
| decode 是否产生新帧 | `DecodeSession` snapshot 已有，但 Registry 丢弃 | `DecodeRegistry` 返回 snapshot，Coordinator 比较 | 仅有效变化唤醒 upload |
| 动画 canvas 合成 | native `media_core` WebP cursor | 同左 | 对照只读 VibeVenera/libwebp 修正 sub-rect、blend、dispose |
| 平台 texture 上传串行 | `UploadSession` | 同左 | 保持，验证旧 revision 不并发写同一 slot |
| 网络 chunk telemetry | `DownloadSession` | 同左 | 生产侧按累计字节/终态批量摘要 |
| raw trace ring | App `DebugTraceLog` | 同左 | 继续有界；生产聚合后降低默认导出上限并保留 dropped/aggregated 计数 |
| 连续阅读页面 extent/anchor | `ReaderVerticalGeometry` | 同左 | 纯值测试使用容差，不以 Widget lazy child 证明 |
| controlled response 测试生命周期 | downloads 测试 helper | downloads owner 测试 | cancel/drain/close 顺序显式，禁止等待暂停订阅的 done |

## 被否决方案清单

- 不通过缩小前 7/后 3 下载窗口、2/1 预解码窗口或 5/3/2 lane 掩盖调度风暴。
- 不把动画停滞继续解释为“缺少 source chunk 唤醒”；下载完成后 source 不再增长，frame consume 必须有独立推进事件。
- 不在 Reader/UI 建立动画 timer、cursor 或重试链。
- 不用页面负位移、重叠、裁切或固定高度掩盖横向条带。
- 不通过永久保留所有 texture/cursor 避免重建。
- 不把三万条事件简单截成更少而丢掉错误；先在权威生产者处合并无效/重复 telemetry。
- 不使用真实 loopback socket、固定 `pump`、`pumpAndSettle`、lazy child `.single`、魔法像素或精确 double 相等作为回归。

## Trace 与截图定位结果

- 上传 JSONL 已达到 raw ring 上限 20000 条。事件中 `bytesCommitted=14770`、`decodeStarted=2297`、`uploadStarted=2350`，但 `frameDecoded/framePresented` 各只有 53 条。
- 主要动画页单 identity 记录 2022 次 decode start、2070 次 upload start，却只产生并呈现 48 帧；小网络块常为约 1460 bytes。
- 该页在 source 长度 8191 bytes 时 ready，3012470 bytes 时 sealed。frame 0–47 可呈现，seal 后 holder 被消费却没有新的 source revision，因此旧 Coordinator 不再补帧。
- 截图中的单页内部水平条带不是页面 gap 或 scroll anchor；旧 native decoder 在目标栅格上分别缩放并组合 ANMF 子矩形。动画 rect 的 blend/dispose 应属于源 canvas，现改为源网格合成后整帧一次缩放。

## 实施结果

- `DecodeRegistry.fill` 与 `UploadRegistry.prepare` 返回只读 snapshot，Coordinator 只根据真实深度、终态、epoch/frame 变化推进下游；frame consume 先补 decode，禁止预先提交一次空 upload。
- source wake 按首次 ready、每 64 KiB、seal、failure 合并；frame timer 消费 current output 后使用独立 force decode，不再等待网络增长。
- `DownloadSession` 聚合小 chunk telemetry，并在 seal/failure/detach/reset/evict/dispose 刷新尾包。
- raw export ring 默认从 20000 调整为 10000；UI ring 仍为 500，错误和权威终态不合并。
- 三个 controlled transport 测试改为恢复/取消 iterator 后再等待 close；几何测试使用 `closeTo`。
- WebP native canvas 改为源尺寸，source rect 直接 blend/dispose，完整 canvas 最后一次进入统一 raster。

## 验证状态

- 工作树已通过仓库结构、Dart directive、Pipeline compile boundary、dev.75–dev.82、Reader/Pipeline/UI、Android、Mihon、Venera、外部来源、bootstrap 与 native header 契约；完整 ZIP 经系统 `unzip` 后再次通过关键所有权/平台门禁。
- 使用用户上传的 libwebp 1.6.0 本地源码在工作树和完整 ZIP 解压副本中分别完成 host build，incremental、partial blend 与 finite-loop fixtures 通过。
- 当前环境没有 Flutter/Dart SDK、Cargo/rustc 与 Gradle wrapper，未运行 analyzer、真实 Dart/Flutter 测试、Rust 单测或 Android 构建；截图对应真机页面和完整下载后的循环播放仍需设备复验。
