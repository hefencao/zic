# ADR 0305: Reader re-entry retention 只保留 transfer/encoded authority

- Status: Accepted
- Date: 2026-09-07

## Context

真机加载缓慢期间，`dumpsys meminfo` 显示约 603 MB native allocation / 520 MB native PSS，并伴随密集 NativeAlloc GC。旧 trace 在 Reader route 退出后记录过 `46 download / 20 decode / 20 upload` retained sessions。

`NativeCursor` 在 Rust media core 中持有 encoded `ByteSource` 的 `Arc` 与完整 RGBA decoder canvas；`DecodeSession.detach(retainDepth: 1)` 又保留一张 decoded frame。对约 1072×1608 的页面，一张 RGBA frame 约 6.9 MB。于是短期 Reader retention 会在 physical transfer 已可淘汰/重放时，仍由 Reader-local cursor 钉住整页 encoded bytes、canvas 与 frame。

## Decision

两分钟 Reader re-entry retention 只保留重新进入成本高且属于 transfer 层的状态：physical `DownloadSession`、partial/promoted artifact、encoded ingress/transfer authority。

进入 retained 状态时：

1. 先撤销 Reader demand 与 page output/stream projection；
2. 立即 evict 全部 `UploadSession`，释放 output/frame/texture claims；
3. 再 evict 全部 `DecodeSession`，释放 native cursor、decoder canvas、decoded frames 以及 cursor 对 encoded source 的 `Arc`；
4. 不删除或 reset physical download/artifact authority。

快速重进仍复用同一个 retained `PipelineReaderSession` 与 transfer runtime，但 decode/upload media layer 从 retained encoded authority 重新建立。

2026-09-24 补充边界：这里的“只保留 transfer/encoded authority”约束的是 Reader-owned native media working set，禁止保留 `DecodeSession`、`UploadSession`、native cursor/canvas、decoded frame 或 texture claim。它不要求 Reader route 去失效更长生命周期的 composition presentation generation。external static fallback 可在 retained `PipelineReaderSession` 中保留每个 exact `DecodeId` 的轻量 `externalPresentationCacheIdentity`；该 object 本身不持有 encoded body、decoded raster、frame 或 texture。后续 ADR 0322 将 external-static raster residency 收口到 composition `PipelinePresentationRasterCache`：Reader retention 释放 residency claim，但不旋转 generation identity；若同 raster 仍resident可直接复用，若已被统一 owner 回收则由 owner 的主动 invalidation + 既有 staged refill 补帧。只有 source/recovery/force-reload、decode raster target 或 presentation fit 等真实 generation 变化才可旋转这个 key。普通 route retention/reentry 不是 presentation generation 边界。

## Consequences

- 快速重进不再保证零 decode；通常需要一次本地首帧 decode/upload。
- 以旧 trace 的单帧 decode 约 40–60 ms 为量级，这一成本换取数百 MB native working set 及时释放。
- physical download/partial 与 origin restart 成本不受影响。
- `readerSessionRetained` trace 必须在退出后报告 `decodeSessions=0`、`uploadSessions=0`，并记录本次释放的 media session/byte 数量。
- 后续不得通过扩大 FrameBudget 或 texture pool 重新引入 route-retained media ownership。
