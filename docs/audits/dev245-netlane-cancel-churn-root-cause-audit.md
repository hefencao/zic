# dev.245 根因审计：NetLane cancel churn

## 输入

- 唯一代码基线：dev.244完整包。
- 真机Trace：`zic-debug-trace-2026-08-12T10-54-55.jsonl`。

## Trace事实

共5893条事件、87次`downloadPreempted`。incoming priority分布：1000为59次，780为15次，820为6次，800为5次，900为2次。24个`downloadState=failed`全部是`Failure(cancelled): task was cancelled`，并且都与NetLane `downloadPreempted`相邻，因此本轮没有证据支持继续追Reader dispose/provider lease取消旁路。

59次current preemption的victim base priority全部为0，意味着logical demand已先撤销。可匹配的detach→preempt中位约92.9ms，75%约195.6ms。15个已有committed partial的current victim中11个在200ms内被取消，样本包括约1.62MiB、4.46MiB、8.38MiB、13.13MiB等。normal pressure也会取消已有数MiB甚至约11MiB的task。

## 与旧实验的区别

ADR0183/dev.202曾按不可恢复full-body sunk cost把base0 task提升到接近current-safe headroom，降低churn但设备尾部体验被否决。当前证据是另一类问题：rank在session/role切换后几十到约200ms内发生瞬时demotion，随后立即被scheduler消费。故本轮不扩大restart-cost事实，也不按历史字节长期保护。

## 修改边界

- normal work不再主动preempt最终图片transport；其rank仍决定排队顺序。
- current先使用现有唯一reserved +1 admission headroom；该槽不是“先取消一个victim才能借”的handoff。
- 5+1真正饱和后current仍可preempt。
- Reader active priority下调后使用200ms NetLane-owned demotion grace；到期自动重新pump，重新获得demand则原位升rank并清除保护。
- physical partial、provider task-lifetime稳定、双进度、restart-cost曲线、Venera单context gate均不改。

## 待设备验证

下一Trace重点看：normal 780/800/820/900是否不再产生`downloadPreempted`；第一个blocked current是否直接以handoffActive=1启动而无victim cancellation；快速跨session跳页的recently-demoted transport是否至少越过200ms抖动窗口，若随后仍被current抢占则必须保留同一authoritative partial直线。
