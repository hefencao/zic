# ADR 0182：不可恢复网络 attempt 的 restart-cost retention victim ranking

## 状态

Accepted。建立在 ADR 0181 的 full-body catch-up admission 之上；不替代 admission，也不改变 NetLane 作为唯一网络 rank/preemption owner 的事实。

## 问题

ADR 0181 回答“高成本 full-body catch-up 是否值得开始”，但一旦任务已经开始，既有 NetLane victim selection 仍只比较 demand priority。对服务器不支持 Range 的 full-body response，已经消费的 body bytes 与已经投入的 network-attempt wall time 在取消后都需要重新支付；把一个已投入十几秒、数 MiB 的 780 catch-up 与刚开始的 800 普通 transfer 同等按 base priority 排 victim，会优先杀掉前者，造成真实的时间与流量重做成本。

这里不是因为“CDN 慢”而提高 rank，也不是一般沉没成本保护。只有**取消后必须重新支付**的工作属于 restart cost；普通 strong/validatorless 206 Range 已经凝固进 artifact 的 committed bytes 不进入该模型。

## 决策

1. admission priority 保持现有 Pipeline demand priority，不因已投入成本提高；restart cost 只影响 NetLane 的 active victim selection。
2. `CancelToken` 作为 NetLane-owned task control 接受两类原始成本事实：
   - 当前不可恢复 attempt 从 task 激活起已投入的 wall time；
   - 当前 full-body response 已消费、未来重启必须重新传输的 bytes。
   DownloadJob只报告事实，不计算 rank。
3. 只有 full-body catch-up 真正通过 admission 并准备消费完整 response 后才激活 restart-cost tracking；deferred attempt、合法206 Range与普通 resumable download保持0成本信号。
4. NetLane 将时间与流量分别映射为连续、单调、饱和的 retention bonus：
   - `timeBonus = 60 * (1 - exp(-elapsed / 5s))`
   - `trafficBonus = 40 * (1 - exp(-bytes / 4MiB))`
   合计理论上渐近 +100，而不是硬阈值或线性无限增长。
5. victim比较使用 `retentionPriority = basePriority + bonus`，但 pending/admission排序仍只使用base priority。高投入旧任务不会主动抢新slot，只会在“必须杀一个active task”时更不容易成为最便宜victim。
6. 对配置了current高优先级的NetLane，retentionPriority必须受`highPriorityThreshold - preemptionThreshold`安全上界约束；因此priority1000 current始终可以保留既有40点preemption margin并抢占任何低于current的preemptible任务。
7. NetLane在真正发生preemption时把incoming/base/retention priority、bonus、restart elapsed/bytes写入CancelToken的preemption snapshot；LiveCoordinator只将该snapshot投影为`downloadPreempted` Trace，不反向读取Trace形成策略。
8. endpoint hash、HTTP version、瞬时/平均网速、decode/playback状态都不是retention输入。慢CDN之所以可能获得更高保护，只因为同一不可恢复attempt已经实际支付了更多可重做wall time。

## 后果

- 已投入大量不可恢复时间/流量的background full-body catch-up会优先保留，NetLane更倾向取消成本较低的其它active transfer。
- transition可能在所有可选victim都具有高restart cost时等待正常slot释放；current仍保留强制抢占能力。
- 不新增scheduler、token bucket、带宽分配器或Reader gate；network=5、current reserved slot=1、preemption threshold=40保持。
