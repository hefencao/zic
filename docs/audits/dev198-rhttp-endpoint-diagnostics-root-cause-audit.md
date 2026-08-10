# dev.198 rhttp endpoint 观测缺口根因审计

## 输入

- 唯一代码基线：dev.197 完整 ZIP。
- 真机证据：`zic-debug-trace-2026-08-10T06-36-06.jsonl`。
- trace 大小约 1,269,089 bytes，共 3287 条 JSONL events，说明 dev.197 export compaction 已生效。

## 网络归账

对 origin `sourceRead` 与 `resume*` 归账：

- origin body 约 106,507,765 bytes（约 101.6 MiB）；
- `duplicatePrefixBytes` 约 4,528,116 bytes（约 4.25%）；
- 2 次 strong-validator resume 为 direct 206，重复前缀为0；
- 4 次 validatorless probe 被服务器以200忽略，其中3次 full-prefix catch-up完成，1次在约1.24MB重复前缀后取消。

body concurrency从1增加到5时，按重叠区间估算的聚合吞吐继续增加；current=1000 的 source-plan gate wait中位接近0，剩余 plan时间主要在当前任务自己的Venera hook/origin call。因此没有证据支持降低5路并发、恢复transport framing或新增current独占带宽。

## 观测缺口

当前 product trace 的 `sourceRead` 已有 session-copy `firstChunk/stream/chunks/maxChunkGap`，但没有 `sourceHostHttpVersion/sourceHostRemoteIpHash/sourceRhttpProgress*`。源码确认 dev.197 的 rhttp bridge 仍用 `!dart.vm.product` 同时控制 endpoint元数据与`onReceiveProgress`，所以普通release无法按匿名H@H endpoint分组，也无法选择性打开native receive-progress边界。

正确收口不是默认给正式版常驻高频progress callback，而是把低开销每-response endpoint元数据与高频progress采样拆开：前者默认可见，后者保持显式诊断构建。
