# dev.234 Physical retention 根因审计

## 输入证据

输入为01:41真机Trace，共7964条事件。

- `taskFailed=0`。
- `verified-transfer-acquire-alias`共38次，其中`candidateOwners=2`共4次，4次全部选择`preferred-existing-owner`；`rejected-ambiguous-existing-owners=0`。
- 自动promoted artifact handoff的重复probe已明显收缩，本Trace仅2次`session-artifact-handoff/skip-existing`。
- 四次Reader session dispose开始时，`physicalTransferOwnerShared=true`且共享physical session数依次为43、50、100、107；对应dispose完成事件的`handoffDrainMicros=0`。

## 根因

dev.233正确移除了sessions层“最后claim消失就cold-store”的策略，但应用级`CompositionDownloadTransferRuntime`本身接近App生命周期，registry没有单physical session retirement。于是退出Reader只撤consumer claim，不会回收已经无claim/run/writer的promoted或partial physical session。长期浏览会累积hot session，即使immutable正文已经由ArtifactCacheManager承担长期authority。

这不是Reader retention问题，也不是ArtifactCacheManager容量问题。physical session同时包含transfer task/alias/hot partial状态，唯一有资格决定其退休的地方是拥有这些对象的composition download owner。

## 所有权清单

- `DownloadRegistry/DownloadTransferOwner`：physical session、claim/task/provider机械生命周期；不知道durable policy。
- `PhysicalTransferRetention`：composition hot registry预算及idle victim选择。
- `PromotedArtifactCacheHandoff/ArtifactCacheManager`：immutable durable/equivalent durable authority。
- `PartialDownloadHandoff/PartialDownloadStore`：cold unfinished prefix authority。
- Reader/Pipeline：只表达demand与decode/upload，不拥有physical retirement。

## 实现策略

- promoted idle：等待ordinary artifact handoff成功，再退休physical session；不要求exact durable copy。
- partial idle：默认保留；仅当idle partial超过32项或256 MiB时，按touch order cold-store最旧victim，成功后退休。
- empty idle：压力下可直接退休。
- partial store失败：停止该轮trim并保留hot owner，避免预算机制变成数据丢失路径。
- registry retirement同步删除所有指向该physical ID的acquire-time alias，防止后续identity解析落到已退休owner。

## 明确不做

不恢复claim-detach persistence；不把retention预算放入Reader/Pipeline；不merge已经存在的physical session；不为ordinary promoted retirement强制exact durable；不使用trace或decode水位参与retention决策。
