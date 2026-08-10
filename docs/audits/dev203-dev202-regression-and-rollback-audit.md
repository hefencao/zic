# dev.203：dev.202 体感退化与 retention rollback 审计

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.202_restart-cost-headroom-retention.zip`。
- 真机 Trace：`zic-debug-trace-2026-08-10T11-26-07.jsonl`。
- 对照：dev.201 真机 Trace `zic-debug-trace-2026-08-10T10-55-37.jsonl`。

## 对照结果

离线重建显示：

- dev.201：约57.32 s，136次`downloadPreempted`，约2.37次/s；first-frame 17次，中位约80.4 ms，P90约1.94 s，最坏约2.86 s。
- dev.202：约110.47 s，118次`downloadPreempted`，约1.07次/s；first-frame 30次，中位约63.8 ms，P90约1.60 s，但最坏扩大到约6.84 s。
- dev.202 origin body约257.94 MB，`duplicatePrefixBytes`约29.74 MB（约11.5%）；该比例受操作路径影响，不单独归因于 retention。
- dev.202 只有4次实际preemption携带非零restart-cost；其中base=0样本可得到650/387/811等数百点retention，证明headroom确实改变了victim economics。

因此 dev.202 并非“整体首帧都变慢”：中位和P90反而略好；用户可感知退化来自少数严重尾部，同时headroom对base=0的保护强度明显高于dev.201。设备体验否决了继续扩大该实验的理由。

## 最坏首帧归因

page 209 的 mount→first-frame约6.84 s。当前下载在进入current前已active，随后priority原位升为1000；其最终`artifactSource`显示request-plan约1.63 s、host-open约2.70 s，frame trace的sourceWait最大约6.74 s。该样本没有证据表明current因为retention ceiling无法取得handoff；NetLane的40点边界判定也允许1000抢占960。

另一个约3.19 s首帧同样由sourceWait主导，伴随约0.84 s request-plan + 3.66 s host-open的邻近source open。说明 Venera resolver/host-open冷尾延迟是独立真实问题。

## 决策

1. dev.203仅撤销dev.202 headroom公式，恢复dev.201 bounded +100 retention。
2. restart-cost事实、`downloadPreempted` Trace、dev.199/200 full-body admission/defer全部保留。
3. 不在同一版本顺手修Venera request-plan/host-open，避免混淆因果。
4. dev.203真机优先验证体感是否恢复；随后若仍出现秒级sourceWait，再以request-plan/host-open为独立优化线。
