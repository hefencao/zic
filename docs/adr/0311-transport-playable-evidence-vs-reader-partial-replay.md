# ADR 0311: transport playable evidence 与 Reader partial replay 分离

- 状态：Accepted
- 日期：2026-09-10

## 背景

dev.258 引入 decoder-owned playable-prefix evidence，是为了解决一个明确的 transport flow-control 错误：WebP 的 ANMF structural frame count 可以已经达到预取 frame credit，但 native decoder 仍可能连 frame 0 都无法从当前 prefix 解出。若只凭 structural count park response，页面成为 current 后会重新打开 transport，并把本应提前取得的首帧字节推迟到用户可见路径。

因此 DecodeSession 继续是 playable/first-frame-required evidence 的唯一生产者，DownloadSession 可以在同一 physical generation 内保存这份短期 evidence；但它的行为用途只属于 transport flow-control，用来约束 structural frame proof 何时足以 park body read。

dev.259 为解决另一问题——新 Reader late-join 一个 multi-MB hot WebP partial 时，如果先把整个 physical prefix 重放到 Reader-local native source 才发布，首帧会被本地复制阻塞——引入了先发布最小 probe、再追平 suffix 的 progressive join。该实现后来复用了同一个 playable flow floor 作为 Reader replay watermark，于是前一个 Reader 的 decoder 历史开始改变后一个 Reader 的启动 source 增长。

2026-09-10 真机 trace 证明这种跨层影响真实存在：同一 8.216MB physical partial 的新 Reader initially 只得到 256KiB；一个 Reader 随后产生约 4.5MiB 的 first-frame-required evidence 后，后续 Reader late-join 会在自身 decoder 尚未提出要求前直接按该旧 evidence 扩到约 4.5MiB。physical bytes 本身并未变化。

## 决策

1. 保留 decoder-owned playable/first-frame-required evidence 在 DownloadSession physical generation 内的短期投影，因为 transport flow-control 仍需要它防止 ANMF structural credit 过早 park。
2. 将其行为 API 明确命名为 `transportFlowPlayableFloorBytes()`。Reader-local ingress startup/rebuild 禁止调用这一 API。
3. hot WebP partial 的新 Reader 只从 physical body 发布自己的 source-appropriate 最小 decoder probe（remote 默认 256KiB）。随后继续在同一个 Reader-local native source 上追平当前 physical committed suffix；source revision 唤醒该 Reader 自己的 decoder 实时判断 playable/need-more-data。
4. playable/first-frame-required evidence 不持久化为 partial metadata，不参与 partial identity、validity、verified interval 或 READY authority。
5. 若未来需要把 hot partial 改成完全 decoder-demand-driven 的本地 range hydration，必须单独证明它不会破坏 partial animation loop、live fan-out 与 bounded replay scheduling；不得通过重新共享 decoder proof 达成。

## 影响

- dev.258 的 transport 防早停性质保留，不会退回 structural ANMF count 误判可播放的旧问题。
- dev.259 的首个小 probe 立即发布性质保留，新 Reader 不必等待整份 multi-MB partial 才开始 decode。
- 相同 physical partial 的不同 Reader 不再因为谁先解码过而获得不同的初始 replay watermark。
- physical partial 继续只描述字节事实；Reader-local decoder 继续拥有“当前这些字节能解到哪里”的实时判断。
