# dev.230 hard artifact alias removal 审计

## 23:45 dev.229 真机证据

- 总事件：7525。
- `verified-transfer-acquire-alias`：25次（14 promoted / 9 failed / 2 receiving），`rejected-ambiguous-existing-owners`为0。
- `version-durable-partial-reused`：0。
- `session-partial-handoff/restored-equivalent`真实出现；全Trace `verifiedEquivalentReuse=true`共8次。
- `taskFailed/sessionBusy/writerBusy`：0。
- 104个page host中71个dispose前无首帧，但中位生命周期约34ms、最长约1.53s，主要属于快速scrub/切页，没有新的长时decode failure。

## owner审计

生产代码中hard alias/rekey只剩`ArtifactCacheManager`历史API与显式漫画源迁移`VerifiedArtifactReusePlan.applyExisting()`；Reader/version restore早已使用`registerEquivalences()`。hard alias既不持久proof，也不应控制exact durable write，因此与dev.211–229后的统一模型重复。

## dev.230迁移

- 删除directed alias map/rekey API与ReusePlan mutation helpers。
- 显式迁移无论source artifact当下是否存在都登记verified equivalence。
- ordinary promotion若已有verified equivalent durable artifact则不复制exact body；required command barrier保留exact materialization。
- 更新历史gate为版本感知，禁止为了旧测试恢复hard alias。
