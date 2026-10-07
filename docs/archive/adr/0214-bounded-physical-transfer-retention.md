# ADR 0214：Composition-owned bounded physical transfer retention

## 状态
接受，dev.234。

## 背景

dev.233删除了logical claim detach触发cold partial checkpoint的sessions回调，使hot partial真正属于应用级`CompositionDownloadTransferRuntime`。01:41真机Trace验证multi-owner resolver已不再制造第三owner，但连续Reader dispose时共享physical registry从43增长到50、100、107；Reader自身dispose均明确共享physical owner且handoff drain为0。问题因此从“错误过早持久化”转成“正确共享后缺少composition owner自己的有界退休”。

## 决策

1. `PhysicalTransferRetention`属于downloads composition owner。Reader、Pipeline和sessions都不持有retention budget。
2. idle promoted session先等待既有`PromotedArtifactCacheHandoff` ordinary policy收敛。若immutable body已有durable/equivalent durable authority，可退休hot physical session；不得为退休强制升级成exact durable copy。
3. unfinished idle partial保持hot复用，默认预算为32个idle partial session或256 MiB committed prefix。超过任一预算时按最久未触碰顺序选择victim，经既有`PartialDownloadHandoff`写cold partial成功后才机械退休。
4. cold partial handoff失败时保留hot physical owner；资源预算不能降低数据/复用authority。
5. sessions只提供`takeIdlePhysical/retireIdlePhysical`机械primitive：必须确认无claim、demand、active run、writer、active provider，并清理指向被退休physical ID的acquire-time aliases。它不得引用partial store、artifact cache或retention budget。
6. runtime最终dispose仍执行完整artifact/partial drain，作为composition生命周期最终屏障。

## 被否决方案

- 恢复dev.232以前“最后claim消失即persist partial”：再次把durable policy反向注入sessions，而且Reader churn会制造I/O。
- 每个Reader持有自己的LRU/预算：会把App级唯一physical owner重新拆成多个局部cache policy。
- 超预算直接dispose partial：会丢失已经下载、可继续复用的authoritative prefix。
- promoted session退休时强制exact durable：会破坏dev.230 equivalence-only artifact ownership并重新产生重复body。
- 对多个verified-equivalent physical session做后台merge：仍违反acquire-time-only identity边界；dev.233 resolver已经保证fresh demand择优复用既有owner。

## 观测

`composition-physical-retention`记录retire action及剩余idle session/partial bytes；pressure partial handoff记录`session-partial-handoff action=stored reason=hot-retention-pressure`。这些事件只用于诊断，不参与Reader或NetLane策略。
