# ADR 0221：统一 transfer policy rank

- 状态：Accepted
- 版本：ZIC 0.31.0-dev.241
- Supersedes ADR 0220 的high-priority orphan reclaim分类，以及ADR 0217/0218残留的strict-live/orphan provider调度分支；identity、transport lifetime与single physical owner合同继续有效。

## 背景

dev.237–240逐轮修正了shared partial上的provider lifetime，但provider owner逐渐累积`providerOrphaned`、`high-priority`、`strict-higher`、`task-retained`、`same-exact`等情况判断。与此同时NetLane早已用base priority、preemption margin和restart-cost retention决定普通network task谁应继续占用执行槽。两套规则都在回答“candidate是否值得替换incumbent”，造成同一policy被两个owner重复实现。costly full-body catch-up也在`DownloadTransferOwner`内散落1MiB/8MiB和820/900分支。

## 决策

1. Pipeline继续唯一拥有Reader语义到numeric demand priority的映射；sessions不得识别current/previous等role。
2. NetLane公开`NetPolicyRank`：调用方提供incumbent base priority，NetLane叠加当前active task已经支付的restart-cost retention，得到effective rank；candidate是否胜出统一使用NetLane现有preemption margin。NetLane普通victim选择也使用同一个rank函数。
3. provider lease保留admission priority。active provider claim仍live时以其当前priority作为incumbent base；claim orphan后以lease admission priority作为base。live/orphan不再形成两条调度控制流，只是rank输入来源不同。
4. preferred exact与lease exact相同表示request authority已经正确，属于identity no-op；consumer-bound transport真实dispose不能继续属于lifecycle invariant。这些不是可排序策略，不进入rank。
5. `TransferRankPolicy`统一costly full-body catch-up：将preserved-prefix长度映射为cost rank，将priority与required-completion映射为demand rank，唯一判定为`demandRank >= costRank`。阈值不再散落在physical owner。
6. provider handoff telemetry统一为`takeoverClass=policy-rank`，记录incumbent base/effective rank、retention bonus、restart cost、candidate rank与margin；telemetry不得反向驱动policy。

## 后果

current=1000无需特殊分支即可越过被current-safe ceiling限制的低rank incumbent；普通820/900等claim能否打断已支付attempt由同一个restart-cost rank自然决定。owner控制流只剩不可排序的identity/lifecycle invariant与一次rank comparison，后续调参集中在HeuristicPolicy、NetLane rank参数与TransferRankPolicy，不再新增“某种情况”分支。
