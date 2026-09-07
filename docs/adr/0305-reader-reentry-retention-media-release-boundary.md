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

## Consequences

- 快速重进不再保证零 decode；通常需要一次本地首帧 decode/upload。
- 以旧 trace 的单帧 decode 约 40–60 ms 为量级，这一成本换取数百 MB native working set 及时释放。
- physical download/partial 与 origin restart 成本不受影响。
- `readerSessionRetained` trace 必须在退出后报告 `decodeSessions=0`、`uploadSessions=0`，并记录本次释放的 media session/byte 数量。
- 后续不得通过扩大 FrameBudget 或 texture pool 重新引入 route-retained media ownership。
