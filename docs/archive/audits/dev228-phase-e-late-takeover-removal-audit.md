# dev.228 Phase E late takeover 删除审计

## 设备证据：15:57 Trace

- 总事件：7424。
- `verified-transfer-acquire-alias`：18次，8 promoted / 8 failed / 1 idle / 1 queued。
- `unsupported URI scheme: venera-resource`：0。
- `taskFailed`：0；`sessionBusy`：0；`writerBusy`：0；`decodeState=failed`：0。
- legacy `verified-equivalent-promotion-takeover`：0。
- failed-partial alias可以使用provider exact URI继续进入queued/receiving；Trace中的后续failed均为navigation取消 `Failure(cancelled): task was cancelled`，不是source identity失败。
- `session-partial-handoff`：62次（46 stored / 16 restored）。
- `session-artifact-handoff`：189次（93 skip-existing / 85 skip-cache-resident / 6 stored / 5 stored-resident-cache-authority）。

## Ownership结论

late equivalent-full takeover已经连续在dev.226、dev.227证据中0命中，而acquire-time alias是真实活动路径。Artifact cache promotion observer因此只剩历史补偿职责，继续保留会让durable cache commit拥有physical scheduler副作用。相反partial/artifact handoff仍持续承担physical→durable边界，不能一并删除。

## 删除范围

- composition promotion listener；
- owner independent-exact late takeover method；
- ArtifactCacheManager promotion observer typedef/listener set/add/remove/notify；
- 与上述路径绑定的历史 gate断言。

保留 direct equivalence、acquire alias、durable partial/artifact handoff与exact durable materialization。
