# ADR 0165：rhttp Raw Stream 与 DownloadJob 单一 Framing Owner

状态：Accepted

## 背景

dev.179 为解决 rhttp/reqwest 约 1–16 KiB 小 packet 高频进入 Dart commit 热路径，在 `RhttpSourceResourceDirectTransport` 增加了首 64 KiB、后续 256 KiB 聚合。后续 dev.181 真机 trace 已确认 current 的 `TaskControl` 能以 `controlledFallback=true + priority=1000` 贯穿 artifact read-through，但多个未缓存 current 首帧仍被 2–16 秒 `sourceWait` 主导。

重新对照权威 `vibevenera-master.zip` 后确认，VibeVenera Reader 使用 `streamOnly` direct-stream 路径时并不经过 `images.dart` 的 64/256 KiB coalescing；它把 rhttp stream交给后续 streaming transport。ZIC 自身的 `DownloadJob` 已经有独立且更早的聚合边界：首批约 16 KiB，之后按 `sourceProgressQuantumBytes = 64 KiB` 提交 `DownloadSession`。

因此 dev.179 形成了双重 framing：

`rhttp packet -> 64/256 KiB transport buffer -> DownloadJob 16/64 KiB -> session/native/artifact`

前一层不会减少 DownloadJob 已经负责的 append 次数，却会推迟 source growth 与 decoder的早期 prefix尝试。

## 决策

1. production rhttp direct transport在通过前16字节媒体验证后保持 raw streaming cadence，不建立 page-body chunk aggregation策略。
2. `DownloadJob` 是 transport chunk aggregation唯一 owner：首批约16 KiB，后续按64 KiB source-progress quantum提交。
3. 删除 `RhttpChunkCoalescer` 与其 transport专用测试；保留 `DownloadJob` tiny-packet regression作为权威行为回归。
4. rhttp transport继续负责 request执行、header/range/validator映射、media prefix验证、response lifecycle cancellation；不得拥有 prefetch、retry、priority或 artifact策略。
5. dev.181 的 controlled read-through、Venera single-invocation priority、dev.176 response abort与 retained-receiving继续有效。
6. 不通过缩小7/3、2/1窗口或整章预解析Venera request-plan来补偿该错误buffer。

## 后果

- 底层约1–2 KiB packet仍会被 `DownloadJob` 聚合，不会逐包进入native/artifact。
- decoder最早可在约16 KiB session source growth后开始尝试，而不必先等待transport层64 KiB；后续增长粒度为64 KiB而非被额外256 KiB门槛压住。
- transport与session只有一个framing owner，减少调优分支与后续语义漂移。
