# ADR 0306：Composition speculative encoded read budget

状态：Accepted。

## 背景

Reader 当前保持 canonical previous3/next7 encoded demand，Animated WebP 再由 per-task frame credit 控制 source body 增长。历史 dev.247/248 曾引入默认 50MiB 的 whole-body 估算预算，并让 page eligibility / NetLane admission 读取该估算；dev.249 已因其与 3/7 前瞻浏览、frame-flow 的职责冲突而撤销。近期真机又暴露另一类问题：3/7 中多个 background page 可同时进行网络 source growth 或 durable resident replay，本地 SAF retained range 还可能把 decoder 的大 range 作为一次不可中断 provider `readAt` 提交。这里需要限制的是**实际 speculative encoded I/O working set**，不是重新决定哪些页面有资格存在。

## 决策

1. `SpeculativeEncodedReadBudget` 由 application/composition 持有；默认 50MiB，可由 `readerPrefetchReadBudgetMiB` 动态设置。`cacheLimitMb` 继续只表示持久缓存容量；legacy `animatedWebpPrefetchBudgetMiB` 继续忽略，不迁移为新语义。
2. Pipeline、RoleWindow 与 DownloadDemand 保持 previous3/next7；Animated WebP frame credit、Decode/Upload 水位与 NetLane normal5 + current-reserved1 均不改变。预算不拥有 page eligibility、task identity、retry、cache admission 或 network slot。
3. 网络 physical task 与 Reader resident/local replay共享同一个 composition budget account。只有 priority < 900 且非 required-completion bypass 的**实际新增读取字节**计入 active speculative bytes；current/visible transition 晋升后立即绕过，降回 background 时此前 speculative bytes重新计入。显式 `TransferCompletionIntent.required` 可在同一 physical task 上动态 bypass，不得 cancel/recreate response。
4. 达到预算时只暂停**下一次 encoded read**。source response必须释放 NetLane body-read permit并保留同一 response/StreamIterator/transport lease；预算或priority变化后重新竞争 permit并原地继续。已提交 partial/writer/epoch均保持不变，因此真实 eviction/cancel 后仍沿既有 Range/validator/full-prefix 规则恢复。
5. resident immutable replay在调用 retained bound range authority前再切为 256KiB physical quantum。decoder仍可请求更大的 logical prefix，但每个 quantum 前重新检查 TaskControl、foreground priority、local-read scheduler 与 speculative budget；取消后不得提交下一 quantum。平台/provider若不支持取消已进入的一次 `readAt`，该单次 256KiB operation仍可能物理退场到完成，不能伪称已经中断底层系统调用。
6. budget 是 pause threshold，不是跨任意第三方 transport 的绝对 wire-byte hard cap。transport 已经交付给 Dart 的单个底层 chunk可使计数最多超出一个 provider chunk；local retained replay的该超调由256KiB quantum明确界定。`consumerPacing` transport仍不能承诺native upstream socket完全停止收包。

## 否决方案

- 恢复 dev.247 的2/4 eligibility或让50MiB删除3/7 demand：否决，重新耦合窗口与成本。
- 恢复 dev.248 estimated whole-body NetLane weighted admission：否决，估算值不是实际 I/O，且形成第二套network scheduler事实。
- 把持久 durable 文件大小计入预算：否决；缓存容量和本轮 Reader 实际预读取是不同资源事实。
- 达预算直接 cancel/reopen background task：否决；会丢掉同response pause/resume与partial连续性，并重新放大Range/full-body restart cost。
