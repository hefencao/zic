# ADR 0209：Verified equivalence-aware cold partial restore

- 状态：Accepted
- 日期：2026-08-12
- 版本：dev.229

## 背景

dev.225–228已将live physical sharing前移到demand acquire，并删除late artifact takeover。但版本warmup仍调用`VerifiedArtifactReusePlan.applyDurablePartials()`：把source exact的durable inactive partial复制成target exact的第二份partial，Reader入口还会再异步触发一次。23:03真机Trace中该旧路径仍4次命中，说明它仍是实际补偿而非死代码。

同步`replaceDemands()`属于Reader/pipeline hot planning，不允许为了cold store lookup改成异步I/O；因此cold partial与live TransferKey必须在不同边界解决。

## 决策

1. 删除`VerifiedArtifactReusePlan.applyDurablePartials()`、版本warmup与Reader入口的`_reuseSourceVersionDurablePartials()`复制路径。
2. `PartialDownloadHandoff`接收direct verified-equivalent candidate resolver。physical session prepare先读取exact durable partial；exact存在时始终优先。
3. exact miss时才读取direct verified-equivalent candidates；多个可用candidate选择最长prefix直接恢复到当前physical session，不预先创建target exact durable partial副本。
4. equivalent restore必须清空ETag/Last-Modified；source total length可作为候选metadata保留，但真正continuity仍由`DownloadJob` validatorless overlap/probe规则验证。
5. equivalent restore trace使用`session-partial-handoff / restored-equivalent`并标记`verifiedEquivalentReuse=true`，取代`version-durable-partial-reused`复制诊断。
6. durable lookup继续位于async physical prepare，不进入同步Reader demand normalization/acquire。
7. 本轮不做cold partial全局canonical TransferKey，不事后merge两个physical session，也不改变NetLane、retry、artifact cache、decode/upload/presentation。

## 后果

verified page mapping只登记proof，不再制造第二份cold partial。live physical sharing仍由acquire-time TransferKey负责；cold restart则由同一个physical owner在prepare时消费verified durable prefix。后续若要进一步canonicalize cold TransferKey，必须先有不阻塞Reader planning的durable index/identity设计。
