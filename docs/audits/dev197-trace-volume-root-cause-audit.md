# dev.197 Debug Trace 体积根因审计

## 输入

- 唯一代码基线：dev.196 完整 ZIP。
- 真机证据：`zic-debug-trace-2026-08-10T05-28-25.jsonl`。
- trace 大小约 1,792,434 bytes，共 5502 条 JSONL 事件。

## 网络侧先验核对

本轮先确认“文件大”不是继续掩盖网络重复下载。对 origin `sourceRead` 与 `resume*` 按 identity 归账后：

- 可归账 origin body：约 177,601,680 bytes；
- `duplicatePrefixBytes`：约 2,996,334 bytes，约 1.7%；
- strong-validator resume：3 次，均 direct 206，重复前缀为 0；
- validatorless Range probe 有 2 次被服务器以 200 忽略；其中小 partial fallback 成本约 220 KB，另一条已有约 6.15 MB partial 的 fallback 在追赶约 2.78 MB 后因用户从旧区域远跳而取消。

因此 dev.196 已把 dev.195 约 16.5% 的 full-prefix 重复压到低个位数比例。最大剩余 fallback 在页面失去 demand 后很快取消；为它增加不可抢占或 restart-cost scheduler 会与新 current 争用网络槽，不具备当前证据支持。

## Trace 体积归因

按事件种类统计，较大的高频类别包括：

- `framePipelineTiming`：177 条，约 292.7 KiB，约占 16.7%；
- `bytesCommitted`：344 条，约 153.5 KiB；
- `downloadPriorityChanged`：544 条，约 122.1 KiB；
- `decodeRefill`：433 条，约 117.8 KiB；
- `uploadDemand` / `decodeDemand` / state / frame decode 等也占据较大比例。

其中 download priority、resume、source read、failure/lifecycle 边缘对重建网络状态机很重要，不适合为了体积直接删除。`framePipelineTiming` 与 `decodeRefill` 则是采样型诊断，且 payload 已包含足够的语义字段和可合并统计，适合只在 export projection 压缩。

按 dev.197 语义键和导出时间窗对当前 trace 做离线模拟：

- `framePipelineTiming` 可从 177 条约压到 54 个语义桶；
- `decodeRefill` 可从 433 条约压到 189 个语义桶。

该数字是对现有 trace 的离线模拟，不等价于宣称未来真机文件必然具有固定字节数；实际大小仍取决于用户操作和其它事件。

## 流式过滤结果

新增的 `tool/filter_debug_trace.py` 对同一原始 trace 实际逐行过滤：

- `network`：1627 / 5502 条，约 476,776 bytes；
- `playback`：3479 / 5502 条，约 1.21 MB；
- `failures`：69 / 5502 条，约 16.9 KB。

`network` profile 仍保留 `pageCurrent/pageTransition/policyDecision`、download start/priority/state、resume、artifact/source read/source ready、task failure 等网络分析关键边缘。

## 根因结论

当前首要问题不是网络协议再次退化，而是完整 Debug Trace 将多个高频诊断采样逐条导出。正确收口点是 App export projection 和离线分析工具，而不是修改运行时调度或删减权威网络事件。
