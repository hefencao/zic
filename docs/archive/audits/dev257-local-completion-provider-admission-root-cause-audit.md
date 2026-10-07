# dev.257 根因审计：local completion 误进入 provider admission

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.256_monotonic-physical-flow-frame-proof.zip`。
- 真机Trace：`zic-debug-trace-2026-08-13T04-58-26.jsonl`，3011条事件。

## Trace事实

- `downloadPreempted=0`、download failed=0、`Failure(cancelled)=0`；dev.255 partial lifecycle继续成立。
- `downloadStarted=31`，`flow-satisfied=21`；不存在“此前frame-prefix proof N已经满足、后续正target<=N仍重新start”的样本，dev.256 proof成立。
- 发现3次`downloadStarted`发生在同identity此前已经`artifactPromoted`之后；开始时committedLength分别为16,005,312 / 13,452,574 / 9,775,218 bytes，总计约37.42MiB。
- 这3次start之后均没有对应新的`sourceRead`、`bytesCommitted`或`downloadState=receiving`。相反，`sourceReady`恰好在`downloadStarted`之前出现，说明local prepare已恢复完整source，随后DownloadJob只因入口看到promoted而立即返回。

## 根因

`prepareDownload`属于physical local restore边界，但旧`_runDownload`在prepare结果成为authoritative之前已经按network task思维构造provider transport lifetime：provider引用先捕获，随后record `downloadStarted`，最终才进入`DownloadJob`的promoted/complete short-circuit。

因此“需要一个NetLane task来触发prepare”和“需要一个provider transport attempt”被错误当成同一事实。Trace并未证明真实网络重复下载，但该耦合会污染telemetry/provider lease，并让后续设备分析无法区分local completion与network open。

## 所有权

- local artifact/partial restore：physical transfer prepare边界。
- promoted/complete partial fact：`DownloadSession`。
- local seal/promote无transport完成：`DownloadJob.completeWithoutTransport`共享primitive。
- provider exact/transport lease：仅属于仍需真实network的physical task。
- `downloadStarted`：provider transport attempt事实，不是“NetLane callback开始执行”的事实。

## 决策

prepare完成后先执行唯一local-completion primitive；本地完成则short-circuit，provider lookup/lease和`downloadStarted`均不发生。prepare后重新读取preferred claim，避免跨异步prepare保留旧consumer/provider引用。

## 被否决方案

- 仅把`downloadStarted`改名但仍创建provider transport：只修telemetry不修生命周期。
- 在Reader/Pipeline根据promoted状态屏蔽demand：会把physical completion事实泄漏到presentation/policy。
- 新建第二套local-restore scheduler：当前Trace只证明admission顺序错误，尚不足以引入新的preparation owner。
