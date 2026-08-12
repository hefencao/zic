# ADR 0225：current borrow-first 与 demotion rank hysteresis

状态：Accepted

## 问题

最终图片transport的唯一调度owner已经收敛到NetLane，但10:54真机Trace仍出现87次`downloadPreempted`；24个download failure全部是scheduler cancellation。59次incoming为current=1000，另外28次由780/800/820/900 normal pressure触发。current victim全部已被logical detach降成base rank0，其中detach到preempt中位约93ms、75%约196ms；有committed partial的15次current cancellation中11次发生在200ms内。说明主要问题不是cancel旁路，而是role/session切换先瞬时把active task降rank、scheduler又立即把该瞬时rank当稳定事实。

## 决策

1. 最终图片NetLane删除normal-pressure preemption：低于`highPriorityThreshold`的780/800/820/900只排序、等待普通slot，不主动cancel receiving transport。ADR0168的设备历史保留，但production规则由本ADR取代。
2. `reservedHighPrioritySlots=1`改为真正admission headroom：normal5已满时第一个current直接成为第6个active，不先cancel victim。
3. 只有normal+reserved均饱和且仍有blocked current，才调用统一`NetPolicyRank`选择victim；取消中的task继续占permit直到物理退出。
4. active priority下降时NetLane可应用`demotionPreemptionGrace`。Reader设200ms；窗口内effective victim rank至少为`highPriorityThreshold-preemptionThreshold+1`，因此current不会仅因瞬时demotion立即取消它。priority重新上升时保护立即清除。
5. grace不是新owner：到期由NetLane自身timer重新`_pump()`；pending/admission priority不变，200ms后仍可按既有margin preempt。
6. restart-cost retention公式保持不变，不恢复ADR0183/dev.202按历史投入占满headroom的实验。Venera单JavaScript request-plan gate也保持其独立780 controlled floor；本ADR只约束最终图片NetLane transport。

## 后果

current首次受阻仍可立即借第6槽；快速A→B→C时不会因为刚发生的rank0抖动在几十毫秒内连续杀连接。若所有slot在grace期间都无自然完成，后续current最多等待该有界窗口再重新仲裁，而不是永久失去抢占能力。
