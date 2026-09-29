# ADR 0340：SAF physical partial 先收敛到 Direct staging 再借给热传输

状态：Accepted

## Context

2026-09-29 Profile trace `zic-debug-trace-2026-09-29T03-03-51.jsonl` 暴露了一个看起来像
“已有 partial 却从 0 重新下载”的状态。

其中 page 79 / exact token `6d924728a464c2c6` 已有 7,708,375-byte canonical physical partial。
persistent store 正确找到了该 body，但它只有 SAF locator、没有已证明的 Direct alias，因此
`PartialDownloadEntry.adoptInto == null`。旧路径随后把 SAF body 通过
`PartialDownloadHandoff -> DownloadSession writer` 从 offset 0 重新流入热 session：

- trace 先记录 `physical-partial-opened bytes=7708375 accessMode=saf adoptable=false`；
- 随后同一 physical DownloadSession 进入 `receiving`；
- 本地 checkpoint 重新经过约 1/3/5/7 MiB；
- 该 exact identity 在这段期间没有 origin `sourceRead`。

这不是网络真的重新下载，但它让本地 durable replay 冒充 transport receiving；更重要的是，如果
local preparation 在旧 SAF prefix 全量复制并形成等长 Direct checkpoint 之前被取消，下一次访问仍会
重复同一 whole-prefix replay。

同一 trace 还包含另一类事件：Direct partial 已成功 adoption 后，provider 对非零
`Range: bytes=N-` 返回 HTTP 200/rangeStart 0。那是 provider Range rejection。现有
`DownloadJob` 会保留 partial，并按 rank 做 full-body prefix catch-up/defer；它与本 ADR 的
durable-authority gap 不是同一问题。

## Decision

1. canonical physical partial 若仍由 SAF locator 持有且没有可直接 adoption 的 Direct alias，
   persistent store MUST 在 composition local-prepare 边界内把**同一 physical authority**迁移到
   App-private Direct transfer staging，再把该 spool 借给 `DownloadSession`。
2. 迁移必须完全由 `PersistentDownloadArtifactStore` 的 per-physical serializer 拥有。Reader、
   Pipeline 与 `DownloadSession` 不得建立第二份 partial authority，也不得自行复制 SAF body。
3. authority switch 继续复用既有跨-locator physical-partial migration：
   - 旧 SAF prefix checksum/locator proof；
   - Direct staging body；
   - 新 physical-partial row 提交；
   - obsolete-source cleanup debt；
   - 只有新 authority 提交后才退休旧 SAF locator。
4. local-prepare 的 scheduler `TaskControl` 必须进入这次 migration。取消发生在 authority switch
   之前时，较短/未完成 staging 不得覆盖旧 SAF authority；若 Direct authority 已完整提交，则后续
   retry 直接从该 Direct spool adoption，不得回到 SAF whole-prefix replay。
5. migration 完成后使用既有 `DownloadSession.adoptDurablePartialBacking()`，所以 session 一次获得
   已提交的完整 partial length，并保持 idle；禁止为了本地 SAF 搬运把 session 伪装成
   `receiving from 0`。
6. generic stream partial、verified-equivalent candidate 等无法安全移动 mutable ownership 的 backend
   仍可使用原 stream-copy fallback。本决策只提升 persistent canonical SAF physical partial。
7. provider 忽略 Range 时仍按现有 `full-body-prefix-catchup` 合同处理：必须保留 durable partial，
   可以按既有 cost/rank defer，但不能把 HTTP 200 误判成“partial authority 已丢失”而删除/清零。
8. 本决策不改变 7/3 network window、2/1 decode window、NetLane/worker 数量、50MB speculative
   encoded budget、local-preparation cap 或用户最终 SAF download placement。

## Validation contract

稳定回归必须证明：

- 以 SAF 为唯一 locator 的 multi-MiB canonical physical partial 首次恢复后变为同 physical id 的
  App-private Direct staging，并由 hot session adoption；
- 该恢复过程不发布 `DownloadState.receiving`，也不记录 `restored-physical` stream-copy；
- 第二个 fresh hot session 直接 adoption 同一 Direct path，不再读取 SAF body；
- 原有 Direct partial adoption、SAF transfer-checkpoint migration、Range-ignore catch-up/defer 回归继续通过。
