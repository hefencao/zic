# ADR 0184：撤销 headroom retention，恢复 bounded restart-cost retention

## 状态

Accepted。撤销 ADR 0183 的 base→current-safe headroom 投影，恢复 ADR 0182 的 bounded +100 victim-retention 公式；dev.202 的实验历史保留。

## 问题

dev.202 把 restart-cost 0..1 score 投影到 base→960 的全部剩余 rank 空间。该方案减少了 preemption churn，但真机 dev.202 体感较 dev.201 退化。11:26 Trace 中典型首帧中位并未恶化，退化主要出现在尾部；最坏 mount→first-frame 约 6.84 s，主导为 current 自身 sourceWait/request-plan/host-open，而不是明确的 retention victim 阻塞。与此同时 headroom 允许 base=0 retained work 仅因已付成本获得数百点 retention，未来收益已经低时容易过度强调重做成本，且本轮设备证据不足以证明这种更强保护值得承担。

因此本轮不继续拟合 headroom 参数，也不把 source-plan 冷尾延迟与 retention 同时修改。先恢复用户设备上体感更好的 dev.201 retention 基线，再单独研究 source-plan/host-open。

## 决策

1. `DownloadJob` / `CancelToken` 的 restart-cost 事实来源保持不变：只有取消后必须重付的不可恢复 full-body attempt wall time 与 response consumed bytes参与 victim economics。
2. NetLane 恢复 ADR 0182 公式：`timeBonus=60*(1-exp(-elapsed/5s))`、`trafficBonus=40*(1-exp(-bytes/4MiB))`，理论合计渐近 +100。
3. `retentionPriority=basePriority+bonus`，并继续 cap 到 `highPriorityThreshold-preemptionThreshold`；pending/admission priority完全不变。
4. 不保留 ADR 0183 的 `base+(ceiling-base)*costScore` headroom 投影。logical detach 后 base=0 只得到 bounded restart-cost protection，不允许单凭历史投入接近 current-safe ceiling。
5. current=1000、preemption threshold=40、normal network=5、current-only handoff=1、previous=780 等既有配置不变。
6. 本轮不修改 Venera request-plan/runtime、host transport、Range、DownloadJob admission/defer、DecodeSession 或 Reader/Pipeline。11:26 Trace 的 sourceWait/request-plan/host-open 尾延迟记录为独立开放问题。

## 后果

- victim choice重新与当前/近期 demand value保持更强关联，避免 retained-background base=0仅因历史投入获得数百点保护。
- dev.201 已观察到的“有成本就适度保护、但不让过去投入压倒当前收益”重新成为生产基线。
- 若 dev.203 真机体感恢复，可把 dev.202 的退化判为 headroom experiment failure；若仍有 3–7 s 首帧尾部，则下一步应独立处理 source-plan/host-open，而不是继续调 retention。
