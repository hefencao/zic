# ADR 0097：持久 Artifact 直连 Ingress 与 Texture Lease 池

**状态：Provisional**

## 问题

dev.112 设备 Trace 证明全局页面下载并发上限和页面 rank 已生效，且没有 decode、native blit 或 Flutter fallback failure；但首次进入和快速重进仍然缓慢。

三个长尾相互独立：

1. persistent/memory tier 命中后，完整 5–20 MiB 页面仍被复制到新的 Reader `DownloadSession`，再次写入临时 artifact，再提交 native ingress；持久缓存被当成一次新下载。
2. 每个 Reader runtime 都重新创建 Android texture output。第二、第三次进入的 current frame 0 `outputPrepare` 分别约 1.07 秒和 0.62 秒，明显高于 source wait 与 native decode。
3. `waitingSource` DecodeSession 在 source revision 未变化时仍被普通 force/ticker 重提，产生大量无产出的 refill、lane 和 Trace 工作。

## 决策

1. `ByteResponse` 明确区分 `staged` 与 `durableImmutable`。只有由 `ArtifactCacheManager` 证明来自 durable backend，或由该 durable entry 填充的 memory tier，才标记为 `durableImmutable`。
2. durable cache response 仍进入权威 `DownloadSession` 和 `Ingress`，但不获取 artifact writer、不写 partial/final 临时文件。session 记录 resident length、epoch、source-ready、seal 和 promoted 状态；失败时 reset 回 idle 以便重试。
3. origin、partial、resume 与 memory-only session artifact 继续走 staged writer；L1 可读不能冒充 L2 已持久化。
4. `NativePipelineMediaRuntimeFactory` 持有 composition 级 Android texture lease pool。Reader runtime 只租用和归还 lease；相同尺寸的 idle lease 可跨 Reader 重进复用。
5. current observation 到来时使用 `PageAsset.width/height` 并行预热真实尺寸 output。预热失败只记录并回退到 lazy create，不影响 Reader。
6. DecodeSession 为 `waitingSource` 且没有 source wake 时不再重复提交。source 首次可用、每 64 KiB 增长、seal、failure 或 demand revision 变化仍可唤醒。

## 所有权

- cache tier 与 durability 判定：`downloads`。
- source/session epoch、seal 和 writer：`sessions`。
- current 页面尺寸投影与 runtime composition：`pipeline_runtime`。
- Android texture lease 生命周期：`pipeline_native` + `texture_bridge`。
- Reader/App 不直接持有 cache body、Ingress、texture lease 或 pool。

## 拒绝方案

- 绕过 DownloadSession，直接让 decoder 读取 cache bytes：会建立第二套 source/session 生命周期。
- 把 memory hit 一律视为 durable：可能跳过必要的 backend write-through。
- 每次 observation 都创建一个新预热 texture：会把预热变成新的资源泄漏。
- 仅增大下载并发或 decode 水位：不能降低 cache-hit staging 和 output create 长尾。
- `waitingSource` 使用周期 ticker 重试：没有新字节时只增加主 isolate 工作。

## 解除 Provisional 条件

设备 Trace 证明：durable cache 命中产生 `cacheResident=true` 且 `artifactWriteMicros=0`；快速重进出现 `textureLeaseReused=true`；current frame 0 的 output prepare 明显下降；waitingSource 无新 source revision 时不再重复产生 refill；首次进入和重进的 mount-to-first-frame 得到改善。
