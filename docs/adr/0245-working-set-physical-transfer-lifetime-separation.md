# ADR 0245：Reader working set 与 physical transfer lifetime 必须分离
> dev.268：ADR 0246 supersede本ADR的normal `inactive-reclaim`子句；working-set/physical-task lifetime分离原则继续有效，inactive live response改为park并释放body-read permit。

- Status: Accepted
- Date: 2026-08-13

## Context

dev.264–266连续围绕同一症状增加了flow-yield、near-two保护与浏览方向预测，但13:50 dev.266真机Trace再次证明这些下游规则没有解决所有权问题：current从99仅移动到98，policy就从`readDirection=+1`切到`-1`，同一revision连续对page102–106五个download claim发出`demandDetached`。调高方向切换阈值只能推迟批量detach；只要“退出3/7 working set”还能直接决定已admit physical task的结束，确认转向时仍会重复断流。

只读VibeVenera对照给出更稳定的边界：working-set迁移可以取消尚未运行的queued task，而已经运行的`StreamingDownloadTask`声明`retainWhenInactive=true`，不会仅因离开active key set被取消；真正容量竞争由scheduler统一处理。ZIC在dev.243已有“active claim归零降rank0、queued可删除”的一半语义，但NetLane没有一等的“是否仍有consumer demand”状态，dev.262 no-Range continuity占槽后才被迫在DownloadJob/flow/page-distance层猜测谁可以让槽。

## Decision

1. Pipeline唯一拥有Reader browsing intent、previous3/next7 logical DownloadDemand、decode2/1、role/rank与5/3/2/1 body credit；这些事实只回答“现在需要什么”，不回答“已经开始的physical transport何时死亡”。
2. `DownloadTransferOwner`唯一把aggregate consumer claims投影为physical task的scheduler demand state：有任一claim时`demanded=true`；最后claim消失时，queued且尚未admit的task可直接移除，already-admitted active task必须保持同一task key、降priority 0并标记`demanded=false`，不得因working-set变化调用cancel。
3. `NetLane`把`demanded`作为active/pending task的一等调度状态。normal pending work没有容量时，只能回收`demanded=false`且preemptible的active physical task；`demanded=true`的active task不得成为normal-capacity reclaim victim。bucket满时victim仍必须来自相同bucket。
4. inactive reclaim使用既有single-flight cancellation事务：只设置同一个CancelToken的typed preemption，等待victim真实退出后才释放permit，再pump pending。不得提前释放容量，不得建立flow-level cooperative yield或第二scheduler。Trace必须以`preemptionReason=inactive-reclaim`区分该路径。
5. dev.264的`flowRetentionYieldable/requestFlowYield/pseudo-yielded` normal slot机制与dev.265的`protectFlowRetentionFromNormalYield`全部废弃；NetLane不再读取Range、flow target、Reader距离或next/previous角色判断inactive reclaim资格。dev.262仍保留：no-Range consumer-paced response在body credit满足后不自行关闭，Range-capable非adjacent response仍可安全flow suspend。
6. 浏览方向仍属于Pipeline纯工作集优化，但dev.266的weighted/dwell trend被废弃。方向只从committed page change学习：第一次反向只形成candidate，第二次连续同向反向才确认；scrub/jump/abs(delta)>5清除candidate且不学习。RoleWindow、rank与5/3/2/1继续共享一个`readDirection`，但该状态绝不能成为transport cancellation authority。
7. consumer-bound transport真实consumer dispose、显式owner dispose、真实network/content failure与既有current-only destructive preemption仍是独立的physical attempt终止边界；这些边界不得伪装成3/7 membership变化。

## Consequences

- 99→98的一页短反向不再翻转整个3/7；最多按同方向滑动一个边界。即使之后真正确认转向导致旧侧多个logical claim退出，已经admit的physical tasks也只变成inactive retained tasks，不会由detach本身批量cancel。
- 只有真实容量压力才会让一个已经没有consumer demand的active task退出；重新转回窗口时若它尚未被真实回收，同一个task key原位恢复`demanded=true`与当前priority，不产生第二次network task。
- previous3/next7、decode2/1、body5/3/2/1、holder7/5/3/2、NetLane normal5+current reserved1均保持；不新增连接数、grace、near flag、flow-yield flag或Reader-owned网络状态。
- ADR 0242、0243、0244均Superseded；它们保留历史Trace与失败路径，但不再描述production控制流。
