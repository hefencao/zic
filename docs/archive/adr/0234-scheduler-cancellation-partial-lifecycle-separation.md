# ADR 0234：scheduler cancellation 与 partial lifecycle 分离

状态：Accepted

## 问题

03:19真机Trace中8次`downloadPreempted`的victim全部为base rank0；5次拥有真实committed partial的attempt在被NetLane preempt后紧接着进入`DownloadState.failed / Failure(cancelled)`，合计约35.67MiB。相同physical partial在两次preempt后约364ms与618ms重新获得priority1000/820 demand。这里被取消的是一次transport attempt，不是authoritative encoded partial；把scheduler cancellation写入content failure会污染source/progress/reuse语义，并让前后页恢复看起来像“partial被cancel”。

## 决策

1. `ErrorCode.cancelled`是attempt-lifecycle结果，不得成为`DownloadSession.failure`或`DownloadState.failed`。
2. `DownloadJob`在validator probe、full-body catch-up与ordinary body任一路径收到typed cancellation时，必须先flush已经收到的authoritative bytes，再关闭response iterator，并把writer交给`DownloadSession.pause()`；committedLength/Ingress/epoch保持不变。
3. `DownloadSession.fail()`本身承担最终防线：typed cancellation必须机械转为`pause()`。任何更高层调用方都不得通过generic fail closure重新污染partial。
4. NetLane destructive preemption语义不变；`downloadPreempted`继续记录attempt被scheduler终止，并只读附带`partialPreserved/partialState`。该telemetry不得反向形成rank policy。
5. 真实network、content、validator、artifact corruption等错误仍可进入failed。queued never-admitted cancellation、explicit user stop与consumer-bound capability destruction仍按各自生命周期结束attempt，但若已有authoritative writer bytes，同样不得把typed cancellation写成content failure。
6. 本ADR不改变scrubbing current-only demand、3/7窗口、动画frame credit、NetLane 5+1、100ms stable current candidate或restart-cost公式。

## 后果

前后页/跨Reader短切仍可能在真正饱和时结束一次低rank transport attempt，但partial保持idle且可直接resume；scheduler state与content validity不再互相伪装。若后续Trace仍证明连接本身被过度preempt，应在demand/workset ownership上独立处理，不得再依赖failed-partial兼容语义或提高committedLength retention bonus掩盖。
