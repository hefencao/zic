# ADR 0228：动画 speculative encoded work 的 byte-weighted NetLane admission

状态：Superseded。细化 ADR 0227 的 50MiB 预算语义；不改变 RoleWindow、2/4 最低资格、3/7 上界、水位顺序或 ADR0226 destructive-preemption transaction。

## 问题

dev.247 将动画 WebP demand 从固定 3/7 缩到 previous2/next4，并以 50MiB 预算阻止外层扩张。14:13 真机 Trace 显示 preempt 已降至13次，但动画 active 时46次 lower-window policyDecision 仍固定估算约72MiB（6个 speculative×未知12MiB），因此默认50MiB只产生 `minimumExceededBudget`，不能减少已经 eligible 的同时执行工作；水位 stage 即使提高也几乎没有机会开放 outer page。页数资格与 active network cost 仍被混为一个概念。

## 决策

1. `RoleResolver` previous3/next7 继续是唯一逻辑/retention window。
2. `AnimatedPrefetchPolicy` previous2/next4 继续是最低**预下载资格**集合；`c>4/n>2/c>6/n>3`只把 next5/previous3/next6/next7 加入 eligible demand，50MiB 不再从 Pipeline 删除这些候选。
3. `DownloadDemand`/`TransferDemand`只携带通用 `estimatedTransferBytes`、`speculativeBudgetBytes` 与 foreground-exempt priority；它们不是第二个 scheduler。
4. `NetLane` 是唯一执行 admission owner：budgeted pending task 只有在 active speculative encoded cost + candidate cost 不超过 candidate budget 时才可占普通 slot。未知动画页默认估算12MiB，因此50MiB通常最多同时运行4个 speculative transfer。
5. priority>=900 的 current/visible transition 不计 speculative budget，但成本元数据仍随 physical task 保留；其 priority 降低后无需重建 task 即开始计入预算。active cost临时超过预算时不cancel既有连接，只阻止新的budgeted speculative admission。
6. 单个 eligible page 的估算成本大于整个预算且当前没有其他 speculative active 时允许独占一次，避免永久 starvation。
7. count concurrency 5、current reserved +1、100ms stable destructive-preemption candidate 与 single-flight victim 均保持。weighted budget只能减少 speculative admission，不能新增 cancellation。

## 后果

2/4下界不再意味着7个大文件必须同时占网络。水位可以正常把外层页加入队列，而50MiB真正限制并行的大体量动画工作；当前页切换时通常仍有普通/保留容量可用，从源头减少为了 current 产生的 destructive preemption。static 或未启用动画成本策略的 demand 不受此 weighted budget 影响。

## 否决方案

- 把 previous2/next4 再缩成1/2：破坏用户指定的最低预下载资格，且重新混淆逻辑邻域与执行容量。
- 全局把 NetLane 5 路降成3/4：会无差别伤害静态图片与小文件。
- 继续增加 preemption grace：只推迟 cancel，不减少制造压力的 speculative work。
- 预算继续只阻止 outer page：本 Trace 已证明 floor 自身就可超过预算，默认50MiB因此形同虚设。
