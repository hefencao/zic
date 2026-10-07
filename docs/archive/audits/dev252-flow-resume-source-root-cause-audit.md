# dev.252 根因审计：图片打不开与预下载resume自锁

输入：唯一代码基线dev.251完整包；真机Trace `zic-debug-trace-2026-08-12T23-17-50.jsonl`。

Trace共10000事件：33次真实`paused`、14次`resumed`、18次current preempt；14/18 victim在被抢占前最后flow状态为paused。另有1次`sourceDisabled`，错误明确为`native source was already sealed during reserve expected length`；两次network `taskFailed`均为`Bad state: StreamSink is bound to a stream`，且发生在rhttp direct长时间hard pause后恢复。

代表性resume自锁：physical partial已有614660 bytes/5帧，新attempt从0追赶时targetFrames=3，却在networkCursor=373760 < committedLength=614660处pause；另有253662-byte partial在networkCursor=24286处被target=1阻塞。这些字节只是重放已有authority，不应受speculative frame credit限制。

修复只落在Ingress expected-length时序、DownloadJob frame gate与rhttp capability；不修改预下载窗口、水位、NetLane或partial identity。paused task仍占normal body slot的问题继续独立保留。
