# dev.199 full-body catch-up 重复流量根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.198_product-safe-rhttp-endpoint-diagnostics.zip`。
- 真机 trace：`zic-debug-trace-2026-08-10T07-51-47.jsonl`。
- trace 大小约 1,506,800 bytes、4436 events；dev.197 的 export compaction 仍生效。

## 网络归账

对 38 条 origin `sourceRead` 与 `resume*` 生命周期归账：

- origin body：约 123.17 MiB；
- `duplicatePrefixBytes`：约 19.21 MiB，占约 15.6%；
- strong-validator range：5 次 `resumeAccepted`，全部 `206 + direct + duplicatePrefixBytes=0`；
- full-body prefix catch-up：14 次启动，10 次完成、2 次在旧 boundary 前取消，另2次在 trace 结束时仍未形成 terminal resume 事件；
- HTTP version：38/38 为 HTTP/1.1；
- 匿名 endpoint 共23个，按每 endpoint 的可观测 body bytes/stream time 汇总，吞吐约从 0.14 MiB/s 到 2.16 MiB/s，中位约0.72 MiB/s，证明 CDN endpoint 差异真实存在，但不能解释 19.21 MiB 的确定性重复前缀。

source-plan cache 本轮 16 hit / 22 miss；hit 的 plan 中位约13 µs，miss 中位约1.61 s。该现象继续作为 request-plan 优化候选，但 current gate/preemption并未出现需要立即修改 network=5 的新证据。

## full-body fallback 的角色分布

14 次 `full-body-prefix-catchup` 启动时的动态 priority 主要为：

- 760：1次；
- 780：3次；
- 800：6次；
- 820：1次；
- 900：1次；
- 1000：1次；
- 其余1次来自相邻时序记录。

代表性重复包括：

- 同一 DownloadId 在 priority780 下以约2.10 MiB partial启动 full-body catch-up，之后又在 priority780、约3.87 MiB partial阶段再次启动；其中一次在追平旧 boundary前已重复读取约1.42 MiB便被取消。
- 另一 DownloadId 在 priority800、约1.79 MiB partial下多次启动；一次只重读约48 KiB便被取消，后续同一背景角色又重新从0开始。
- 多个 priority800 partial 已达到约1.55、2.21、3.76、5.82 MiB，仍会为普通背景预取承担完整旧前缀重读。

因此本轮的主要问题不是 Range 协议再次失效，而是：**服务器已经明确要求 full-body continuity proof 后，sessions scheduler仍把高重启成本任务当作普通 background prefetch反复调度。**

## 选择

不采用“catch-up 一旦开始就禁止抢占”：用户远跳时旧任务必须让位给新 current，否则会把重复流量问题变成无用旧页占槽问题。

不采用 endpoint/hash 驱动 policy：endpoint 观测只说明 CDN差异，不能成为业务调度身份，而且 dev.198 已明确其 observation-only 属性。

采用 sessions-owned cost-aware admission：保留低成本小 partial；对 >=1 MiB 的 full-body catch-up，仅 dynamic priority >=820 时允许。Range probe仍先执行，因此真正支持 Range 的服务器不受该门槛影响。
