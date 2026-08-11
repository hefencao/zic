# dev.210 根因审计：旧版更新提示、冷启动 Reader 阻塞与 partial 复用

## 设备证据

输入：`zic-debug-trace-2026-08-11T01-09-52.jsonl`。

- Home启动、插件host与封面在约1.07s内完成主要可见恢复。
- 下一条关键版本复用事件直到约13.96s才出现：`version-artifact-alias-prepared`，其后约14.08s才创建371页Reader。
- Reader创建后当前页约0.27s first-frame；多个page立即从persistent artifact读取。因此长时间不可操作发生在Reader route创建之前。
- trace后段存在多个`session-partial-handoff` durable partial，大小约0.5–14MiB，说明partial已有独立durable owner；此前版本reuse只查询promoted ArtifactCacheManager，因此partial天然无法命中。

## 源码根因

1. `_prepareImportedChapter()`同步`await _prepareSourceVersionArtifactReuse(current)`；该函数对opaque Venera page locator调用`verifiedPageReuseIdentity`，可触发source runtime/request-plan网络工作。
2. dev.207/208只把temporary artifact alias持久事实放在内存，未持久化已经验证的page offset；冷启动只能重新证明映射。
3. source-card更新判断曾用raw alias集合同时排除successor；当raw URL格式/alias集合变化时可吞掉confirmed predecessor提示。
4. `VerifiedArtifactReusePlan`只面向promoted artifact；durable partial没有跨版本复用路径。

## dev.210 收口

- 持久化`ComicVersionPageMapping`，详情/Reader入口后台预热mapping。
- Reader同步路径只恢复local mapping→promoted alias，不调用source resolver；后台继续刷新供后续访问。
- partial仅复制durable inactive prefix到verified target ID，validators清空；真实网络resume仍由validatorless overlap验证。
- `!`以predecessor/successor raw+canonical identity明确区分，relation不写`sourceUpdateAt`。
