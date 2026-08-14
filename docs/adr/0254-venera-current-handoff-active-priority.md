# ADR 0254：Venera current handoff 的 active priority 重新评估

- 状态：Accepted
- 日期：2026-08-14

## 背景

05:37 dev.275 Trace显示resolver long-cache上移后，warm request-plan多数仍为3个bridge cache hit加1个page-specific origin，但Venera单invocation gate等待中位约669 ms、最坏约3.89 s。dev.274已经保证priority1000 current先进入network/source admission，因此剩余等待发生在runtime gate内部。

现有gate会在新waiter入队、或waiter升到current阈值时检查controlled preemption；但已经active的旧current若随后降级，gate不会重新比较已经等待的新current。这使viewport已经完成handoff后，旧页仍可继续占唯一JavaScript context直到整个resolver invocation自然结束。

## 决策

1. Venera仍保持`maxConcurrentInvocations=1`；不复制JavaScript context、不并行执行source request-plan。
2. `_RuntimeInvocationGate`继续是runtime invocation排序/抢占唯一owner，并监听controlled active invocation的`PriorityObservableTaskControl`。
3. 只有active priority从current-class阈值（1000）向下跨出，同时队列中已存在current-class waiter时，才重新执行既有controlled preemption判断。
4. 重新判断仍使用既有40-point阈值与requestId cancellation；请求取消不得提前释放single permit，必须等旧invocation真实退出。
5. 普通非current角色降级（例如820→700且waiting previous=780）不触发该handoff机制，避免viewport jitter转化为破坏性取消。
6. dev.275 host resolver cache、NetLane、3/7、5/3/2/1以及source host transport均不改变。

## 结果

current handoff的动态priority变化不再丢在active invocation生命周期内；runtime gate对waiter promotion与old-current demotion形成对称闭包，而不引入第二套scheduler或额外并发。
