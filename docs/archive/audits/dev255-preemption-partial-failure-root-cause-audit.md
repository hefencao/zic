# dev.255 根因审计：preemption 不得把 partial 写成 failure

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.254_decode-ingress-epoch-bounded-flow-suspension.zip`
- 真机Trace：`zic-debug-trace-2026-08-13T03-19-56.jsonl`

## Trace事实

- 总事件7310；`downloadPreempted` 8次。
- 8个victim在仲裁时`basePriority=0`，incoming均为current=1000；本Trace未证明NetLane直接杀仍有正download demand的前后页task。
- 5个preempted attempt拥有committed partial并紧邻`DownloadState.failed / Failure(cancelled)`：5,259,264 / 4,275,653 / 2,041,080 / 14,386,840 / 11,436,032 bytes，合计约35.67MiB。
- 同一physical identity两次被preempt后分别约364ms与618ms重新获得priority1000/820 demand；第二次preempt时已有约11.4MiB partial，随后同一physical owner继续被alias/demand复用。
- `taskFailed=0`、`sourceDisabled=0`；问题不是内容损坏，而是transport cancellation错误污染DownloadSession内容状态。

## 所有权清单

- NetLane：是否终止当前transport attempt。
- DownloadJob：response/iterator、chunk flush与writer attempt closure。
- DownloadSession：authoritative partial bytes、writer、idle/failed/promoted内容状态。
- Pipeline/Reader：只提交logical demand，不得根据`downloadPreempted`直接改变partial validity。
- Artifact/Ingress：只反映DownloadSession authoritative bytes，不得把scheduler cancellation解释为内容failure。

## 被否决方案

- 给committedLength直接增加大额retention bonus：普通Range-resumable partial不是不可恢复sunk cost，会重做已否决的headroom保护。
- 延长100ms current candidate或再加500ms/1s victim grace：本轮首先存在明确状态语义错误，不能用时间阈值遮蔽。
- 修改scrubbing current-only或3/7：Trace中的preempt victim均已rank0，但不足以证明窗口policy本身错误；应与partial validity修复分离。
- 继续允许`failed + Failure(cancelled)`并依赖“failed partial仍可复用”的历史兼容语义：会让source/progress/retry永远同时解释attempt与content两种状态。

## 决策

typed cancellation统一flush + pause writer；`DownloadSession.fail()`再次机械保护该不变量；真实错误才进入failed。NetLane和Pipeline policy本轮不改。
