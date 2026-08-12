# dev.248 根因审计：动画预算只裁页数，未约束 active encoded work

## 真机证据

输入：`zic-debug-trace-2026-08-12T14-13-54.jsonl`，共6756条事件。

- `downloadPreempted=13`，较前轮继续下降，说明 ADR0226/0227 已有收益，但仍有 stable current 需要取消 background transport。
- `policyDecision`：downloads=1 共136次（scrub/current-only）、downloads=7 共46次、downloads=11 共19次。动画策略确实把普通窗口从11缩到7。
- 动画 active 的46次非current-only lower-window决策全部估算 `75,497,472 bytes`（72MiB），且全部 `minimumExceedsBudget=true`。原因是 previous2+next4 六个 speculative unknown page×12MiB 已超过默认50MiB。
- 因此 dev.247 的50MiB只阻止 outer expansion；它不能阻止 lower-window中第5/第6个大文件进入NetLane。开场实际 current+4个speculative 已约48MiB，随后第5个speculative仍可启动并把 active 推到6，重新吃掉current handoff余量。

## 所有权

| 事实/策略 | owner | dev.248 |
|---|---|---|
| previous3/next7窗口成员 | `pipeline.RoleResolver` | 不变 |
| 2/4→3/7哪些页有预下载资格 | `pipeline.AnimatedPrefetchPolicy` | 水位驱动，不再被budget删除 |
| 每页估算encoded成本/配置预算 | Pipeline demand | 只携带只读参数 |
| 同时active多少speculative bytes | `sessions.NetLane` | 新增通用weighted admission |
| physical partial/writer | composition transfer owner | 不变 |
| destructive preemption | `NetLane` ADR0226 | 不变 |

## 被否决方案

不缩RoleWindow、不再延长cancel grace、不降低全局networkConcurrency、不以UI/holder depth决定network eligibility。50MiB必须成为scheduler capacity constraint，而不是第三套窗口。
