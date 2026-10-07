# dev.247 根因审计：动画 WebP 3/7 network admission 过宽

## 真机证据

输入：`zic-debug-trace-2026-08-12T13-06-36.jsonl`，共 7302 条事件。

- `downloadPreempted` 21 次，全部 incoming current=1000，`incomingWaitMicros`约100ms；相比 dev.245/246 前的 cancel burst 已明显收敛，当前主要矛盾不再是 normal-pressure churn。
- idle/scrolling `policyDecision`仍反复输出 `downloads=11`、`decodes=4`，即 full previous3/next7 network demand。
- 4 次 runtime `mediaClassified`均为 `animated=true`、`frameCount=154`。
- 当前章节已观测正文 total/body cost多为十几 MiB；11 页完整 speculative window 的潜在 encoded 体量轻易超过100MiB，因此大量 background active/queued work会放大真正 current 到来时的 slot pressure、provider restart与prefix catch-up。

## 所有权审计

| 事实/策略 | 唯一 owner | dev.247 处理 |
|---|---|---|
| previous3/next7 是否仍属稳定逻辑窗口 | `pipeline.RoleResolver` | 保持不变 |
| 动画页当前 network admission 子集 | `pipeline.AnimatedPrefetchPolicy` | 新增，2/4→3/7 |
| decode staged waterline 实际完成 | `sessions.LiveCoordinator` / `DecodeRegistry` | 只回报 milestone，不决策网络 |
| speculative encoded budget | Pipeline composition/profile | 默认50MiB，可配置 |
| physical partial / writer / alias | composition `DownloadTransferOwner` | 不变 |
| slot/preemption/rank | `NetLane` | dev.246合同不变 |
| UI/Reader window判断 | Reader observation→RoleWindow | 不读取动态admission大小 |

## 关键风险与处理

1. **直接缩 RoleWindow 会让跳页后页面被误判离窗**：因此 dev.247 的 policy只过滤 `DemandPlan.downloads`，RoleWindow 仍有11个角色；新增测试直接断言 current-3/current+7非 detached，而 network stage0只有7项。
2. **classification 太晚，11个请求可能已先启动**：runtime未决议时WebP/animated hint只作为成本风险启用2/4；static decode一旦给出事实即恢复3/7。
3. **旧 current 的 decode refill异步完成后误扩新页**：waterline callback带 plan revision，Pipeline拒绝 stale revision。
4. **50MiB与2/4下界冲突**：下界为硬count合同；预算只控制额外页面，floor超预算显式trace，不静默缩窗。
5. **把水位 owner迁到Pipeline**：否决。sessions仍计算/执行水位；Pipeline只消费“某阶段已成功完成”的只读信号。

## 本轮不处理

- 不修改 dev.246 100ms stable candidate、single-flight destructive preemption、5+1 current reservation。
- 不修改 full-body Range→200 catch-up、restart-cost curve、provider stability或partial persistence。
- 不修改 decode holder maxima 7/5/3/2、decode window 2/1、network/decode/upload normal concurrency 5/3/2。
