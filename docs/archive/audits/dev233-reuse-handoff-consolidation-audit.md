# dev.233 reuse / handoff consolidation 根因审计

## Trace 证据

输入：`zic-debug-trace-2026-08-12T01-05-57.jsonl`。

- 共 7076 条事件；`taskFailed=0`，dev.232 对应的 `partial-source taskFailed` 未复现。
- `verified-transfer-acquire-alias` 共 28 次：26 次 `joined-existing-physical`，2 次 `rejected-ambiguous-existing-owners`。
- join 的既有 owner 状态包含 promoted、failed、queued；Trace 中 25 个 `downloadState=failed` 的 failure 全部是 `Failure(cancelled): task was cancelled`，没有证据支持把 failed partial 当作损坏 owner。
- ambiguous 事件发生前已经存在可复用 physical owner；旧 resolver 因第二个 candidate 出现就返回 fresh exact ID，随后又建立新的 physical session，因此 ambiguity fallback 本身会增加 owner 数量。
- artifact handoff 中观察到大量同一 identity 的 `skip-existing` / `skip-verified-equivalent-durable` 重复；这些发生在 immutable promotion 完成后的 demand/snapshot churn，不代表正文发生变化。
- 本 Trace 仍未出现 `stored-required-exact-alias`，因此 dev.231 的 Reader A + required B exact durable 设备验证继续保留。

## 根因

1. verified acquire resolver 只有“唯一 candidate 才 join”的二元规则，没有“多个已经存在 authority 中选择一个”的归一化步骤。
2. `DownloadTransferOwner` 同时承担 scheduler 和 “unclaimed 时是否写 cold partial”策略，通过 callback 把 downloads persistence 生命周期泄漏进 sessions。
3. promoted handoff只对“正在执行的 Future”去重；Future 完成后不记得 immutable session已经处理过，所以任何后续 promoted snapshot 都会重新做 durable lookup。

## 实现收口

- resolver 对 direct verified existing candidates去重并做稳定 authority 排序；fresh exact只 alias 到最优 existing owner，诊断新增 `candidateOwners` 与 `selection=preferred-existing-owner`。
- sessions 删除所有 `persistUnclaimed` API/状态；composition runtime disposal 成为唯一 hot→cold partial handoff 边界。
- promoted handoff新增 automatic-success set；automatic observation幂等，explicit exact `persist`保持强 barrier。
- 行为测试覆盖：final consumer detach仍保留同一 hot partial session；promoted/failed 两个既有等价 owner存在时 fresh identity选择promoted且registry仍只有2个session；重复 drain/snapshot只产生一次 automatic skip probe。
