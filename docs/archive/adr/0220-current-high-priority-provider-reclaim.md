# ADR 0220：current high-priority reclaim orphaned provider authority

- 状态：Superseded
- 版本：ZIC 0.31.0-dev.240
- Refines ADR 0218/0219 的orphaned provider retention；其“high-priority orphan / strict-live”情况分支由 ADR 0221 统一为policy-rank比较。task-retained transport与single physical owner仍有效。

## 背景

05:35真机Trace共4553条事件。跨新旧版本Reader切换时，verified physical alias与aggregate priority迁移都在工作：同一physical `DownloadSession`继续持有partial，`downloadPriorityChanged`可把active task提升到1000。NetLane `updatePriority()`对queued/active priority上升本身也会重新pump，因此问题不是scheduler没有看到current。

真正的不一致位于active provider lease。dev.238为避免claim churn丢弃full-body catch-up，引入`providerOrphaned => retain attempt`；dev.239又允许loader-backed transport越过Reader dispose。于是旧Reader claim已经消失后，其task-retained provider exact URI仍可长期服务physical task。Trace中reader-2/reader-3的current=1000已经接管同一physical task priority，但provider仍是reader-1 exact URI，且整份Trace没有`active-provider-handoff`。调度authority已归current，request/provider authority却没有同步。

## 决策

1. `DownloadSession`、writer、committed prefix与NetLane task仍是唯一physical transfer authority；provider handoff不得复制partial或建立第二task。
2. ordinary orphan retention继续成立：preferred claim低于NetLane high-priority class时，claim generation变化本身不得取消已admit attempt。
3. 若active provider claim已orphaned、preferred exact与lease exact不同，且preferred priority属于NetLane high-priority class，则provider owner MUST取消旧attempt并在旧writer物理退出后以preferred exact provider重开同一physical session。
4. high-priority classification MUST由NetLane公开；`DownloadTransferOwner`不得硬编码Reader role或`priority == 1000`。当前配置的1000只是Pipeline与NetLane既有合同。
5. 若task-retained lease exact与preferred exact相同，即使scope/Reader generation变化也不得rebind；request authority已经正确，无需丢弃已支付工作。
6. active provider claim仍live时维持dev.237 strict-higher规则；equal/lower live claim不得抖动provider。
7. handoff Trace增加`takeoverClass=high-priority-orphan-reclaim|strict-live-priority`，用于设备验证，不反向驱动策略。

## 后果

current重新获得与其scheduler rank一致的provider/request authority，跨版本切换不会出现“priority=1000但仍由旧版本URI继续服务”的半迁移状态。普通预取/邻页仍保留dev.238/239减少重复catch-up的收益；same-exact retained transport也不会因route generation变化重开。restart-cost retention、Range/full-body admission、network=5+reserved1均不变。
