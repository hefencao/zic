# dev.183 Current 首帧 policy / execution 根因审计

## 结论

用户对 dev.182 性能解释的质疑成立：64KiB 与256KiB transport framing在绝大多数实际高分辨率漫画与正常网络条件下，不足以解释数秒到十几秒的首帧抖动。该改动可以作为重复 framing owner清理，但不应被当成主要性能修复。

本轮重新对 `zic-debug-trace-2026-08-09T08-12-07.jsonl` 做端到端检查，并只读对照 `vibevenera-master.zip` 的 preload/frame-depth/task scheduler。

## Trace 事实

设备 trace 中首帧 mount 延迟同时出现约0.18s、2.31s、2.76s、2.87s、3.68s、5.20s和12.19s。慢页首帧的 native decode通常只有约30–60ms，主要等待落在 source/policy execution。

更关键的是：

- 多轮 policy 同时报告约7个 `staticWarmDecodes` 和4–7个 `staticWarmUploads`；这意味着静态推测把远页从 encoded-only 窗口提升成 decode/upload执行。
- 部分 DecodeSession 在页面成为 current 前已经以 neighbor身份进入 `waitingSource`，`sourceWait`会跨多个policy revision累计；current到来时只改priority，并不代表该 execution是干净的前台bootstrap。
- ZIC network已有current reserved handoff，但 decode=3、upload=2此前没有相同current-only reserve；当前页首帧因此依赖当时后台decode/upload组合，天然产生高方差。
- Venera native旧cancel会在WebView Promise物理结束之前让Dart invocation完成，从而提前释放“单上下文”permit。由于JS bridge使用全局 active requestId，这种逻辑抢占会破坏物理单上下文假设。

## VibeVenera 对照

当前参考实现的稳定集合是 download前7/后3、decode前2/后1。current缓冲浅时，FrameDepthTable首先让current建立3帧，neighbor target为0；缓冲建立后才逐步扩大neighbor depth。TaskScheduler在network/decode/upload三条lane都给current保留额外dispatch能力。

这说明需要迁移的是 **current bootstrap + execution reservation**，而不是继续改下载chunk大小或缩小预下载窗口。

## 本轮修改

1. 修复 dev.182 `ArtifactCacheReadLease?` nullable访问的真实编译错误。
2. 静态推测只允许稳定decode角色；near/far恢复download-only。真实viewport静态页保留一帧例外，但不引入visible role。
3. current浅水位优先：动态最多3帧，静态1帧；current等待source时仅真实transition可以先取得1帧。
4. DecodeLane/UploadLane接入通用 `_Lane` 的 current-only reserved handoff/preemption，与NetLane保持一致的bounded语义。
5. Venera cancel只发请求并断native HTTP，不提前完成pending result；`finished(requestId)`成为唯一物理退出barrier。
6. 增加行为/静态回归，迁移dev.119/dev.139/Venera preflight中已被新证据取代的旧实现绑定。

## 没有做的事

- 没有缩小7/3或2/1窗口。
- 没有提高normal 5/3/2并发。
- 没有增加Venera JS并发。
- 没有增加新的Reader scheduler、startup-buffer、retry或timer。
- 没有继续以64/256KiB framing解释首帧主延迟。

## 下一步设备证据

优先观察：

- `policyDecision.staticWarmDecodes/staticWarmUploads` 是否从整窗7项收敛到稳定decode角色/真实viewport。
- current depth<3期间是否只出现current refill（current等source时可有transition t>0）。
- current decode/upload在normal lane饱和时是否仍能使用current-only handoff。
- Venera preempt期间是否满足 `cancel request -> native HTTP abort -> old JS finished -> current JS start`，而不是旧/新JS重叠。
- 若上述均成立但origin仍数秒，下一轮应直接细分Venera request-plan/JS bridge/HTTP-open耗时。
