# ADR 0335：Presentation failure 按 volatile raster 与 durable artifact 分层恢复

状态：Accepted

## Context

部分 external-static 页面出现“普通加载失败，必须强制重新下载后才恢复”。
fresh Profile Trace `zic-debug-trace-2026-09-28T14-49-15.jsonl` 把其中一个样本定位到 internal page 90：
同一 physical identity 已以 80741 bytes 完成 exact READY/promotion，并由 detached presentation 成功产出 first frame；
页面后来进入当前 viewport 时却没有 mounted visible first-frame，直到用户执行 `manual-force-reload`。
该命令随后 reset source epoch、重新打开网络并再次得到同样的 80741-byte PNG。

代码审计确认两个不同 failure authority 被混在同一恢复出口：
- artifact-backed file/bytes decode 持有 exact `storageId + generation`，可以证明某一 durable generation 被 presentation 语义拒绝；
- detached resident raster 被 mounted consumer 直接接管时故意不再持有 artifact authority，因为它消费的是
  `PipelinePresentationRasterCache` 已准备好的 completer/raster。
后者一旦 presentation completer/raster 出错，旧 `recoverPresentationFailure` 因 authority=null 直接拒绝自动恢复，
UI 最终只剩 destructive force reload；force reload 因同时轮换 presentation generation 而偶然修好 volatile 状态，
但也无根据地删除/重取已被证明可读的 durable bytes。

## Decision

1. presentation failure 必须先按失败发生的 authority 分层，不按 UI 错误文案猜测资源损坏：
   - resident managed-raster failure 且无 artifact authority：volatile presentation-generation failure；
   - 携带 exact artifact read authority：durable artifact semantic rejection。
2. volatile failure 由 `PipelineReaderSession` 单一治理。
   每页每 Reader session 至多自动一次：
   - 为当前 DecodeId 发布新的 opaque presentation cache identity；
   - 失效旧 managed raster 与 external first-frame satisfaction；
   - 重新交给既有 staged external-presentation grant 获取一帧。
3. volatile recovery MUST NOT 删除 artifact、reset physical `DownloadSession`/SourceEpoch、
   打开 NetLane source、改变 7/3、2/1、Upload/presentation 预算或创建 Reader-local retry owner。
4. replacement identity 必须先发布，再失效旧 raster。
   这样 cache authority 的同步 invalidation callback 不会把显式 fault rotation 误解释为普通 same-generation budget eviction。
5. 携带 exact `storageId + generation` 的失败继续使用既有 `DownloadTransferOwner.recoverPresentationArtifact`；
   只有这一层可以条件失效 durable generation、quiesce physical work、建立 fresh-source quarantine 并重新 admission。
6. 两层 automatic recovery 各自每页/Reader session 最多一次，防止同一失败形成重试环。
   用户显式“强制重新加载当前页”继续保留为最终 fresh-byte 命令，并在成功后清除本 session 的自动恢复额度。

## Evidence

修复前 `14-49-15`：
- page 90 exact artifact 多次以 80741 bytes promoted/readable；
- detached managed raster 已成功 first-frame；
- manual force reload 前缺 mounted visible first-frame；
- force reload 后重新下载仍为 80741 bytes，随后 presentation 成功。

focused regression `media_runtime_ownership_test` 现证明：
- resident-raster rejection 会旋转 exact presentation cache identity；
- staged external-static warm 会重新 grant；
- trace 明确记录 `durableArtifactInvalidated=false`；
- 不出现 `presentation-artifact-recovery`；
- 同页第二次无 authority automatic failure 不会形成循环。
既有 exact-artifact recovery、late-generation guard、mounted generation reload 等测试保持通过。

最终源码 Profile 重新构建并安装后，
`zic-debug-trace-2026-09-28T15-15-40.jsonl` 对同一 physical page identity 再验证：
persistent exact-ready 80741-byte body 直接 local promote，`networkAdmissionRequired=false`；
随后通过 `presentation-file-lease` 读取并产生 mounted visible first-frame，未出现
`manual-force-reload`、`presentation-artifact-recovery` 或 `taskFailed`。
