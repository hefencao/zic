# ADR 0226：稳定 destructive-preemption candidate 与 single-flight transaction

状态：Accepted

## 问题

dev.245 已删除normal-pressure cancellation并让第一个current先借reserved槽，但12:15真机Trace仍有67次`downloadPreempted`，全部incoming=1000。它们只形成28个<=50ms burst，39次属于同一burst额外victim；17/28个burst在100ms内current又变化，覆盖46/67次cancel。`pageCurrent`间隔中位约10.6ms、85%约88ms、90%约594ms，说明快速scrub的临时current与真正停稳current存在天然时间分离。victim-side demotion grace无法阻止一个已稳定rank0较久的连接被每个瞬时current反复杀死，也无法阻止多个preemption同时在flight。

## 决策

1. 保留dev.245 normal work不主动preempt、normal5+current reserved1 borrow-first规则。free/reserved capacity可用时current立即admit，不等待任何稳定窗口。
2. 删除victim-side `demotionPreemptionGrace`。真正需要取消active transport时，high-priority pending candidate必须连续保持high-priority至少`preemptionCandidateGrace`；Reader final-image NetLane设100ms。priority跌出high-priority后稳定计时清零，再次升入时重新开始。
3. destructive preemption为single-flight transaction：若已有由scheduler preemption取消、但尚未从`_active`物理退出的task，NetLane不得继续cancel第二个victim。旧victim退出触发既有`_pump()`，再基于当时最新pending/rank重新决定是否还需要preempt。
4. victim仍由统一`NetPolicyRank`与40分margin选择。普通可Range-resume的`committedLength`不是不可恢复成本，不直接转成retention bonus；只有DownloadJob已经记录的不可恢复restart cost继续参与victim economics。
5. `TaskPreemptionSnapshot`增加`incomingWaitMicros`只读诊断，用于证明破坏性preemption已越过稳定窗口；该字段不得反馈给policy。
6. Venera单JavaScript request-plan gate、consumer-bound硬dispose、显式用户取消和真实错误仍属于各自硬生命周期，不受本ADR的final-image destructive-preemption dwell约束。

## 后果

快速scrub可继续以最新current更新pending rank，但中间页不会在十几毫秒内不断杀active transport；同一个burst最多先产生一个victim，且victim真实退出后才允许下一次破坏性决策。稳定current在5+1持续饱和时最多增加100ms destructive-preemption等待，随后仍保持current抢占能力。
