# dev.211 根因审计：mapping 已完成但迟到 artifact 无法复用

## 输入

- `zic-debug-trace-2026-08-11T02-00-30.jsonl`
- dev.210完整基线
- `vibevenera-master.zip`只读参考

## Trace事实

- 第一次371页Reader前 `version-artifact-alias-restored` 为 `persistentMappings=0/reusedPages=0`；Reader立即创建，证明dev.210已经修复同步resolver阻塞。
- 后台随后在约13.13s、16.53s、22–24s逐步持久化多个 `version-page-mapping-warmed`。
- 再次进入371页旧版前，`version-artifact-alias-restored` 已为 `persistentMappings=3`，但只 `reusedPages=13`。因此“复用不完整”不是mapping未完成。
- 同时377页相关版本Reader仍存活并持续origin下载/完成artifact，直到约71.45s才dispose；dev.210不会在这些artifact后续promote时重新执行`applyExisting()`。
- partial路径已实际工作：trace出现 `version-durable-partial-reused` 50与6，并在后续旧版Reader中恢复多个`session-partial-handoff` durable prefix。

## 根因

`applyExisting()`把“版本页等价”错误实现成“当前文件存在性快照”：只有source artifact在restore瞬间存在才注册hard alias。page mapping是持久事实，artifact existence却是随并行Reader/download不断变化的运行事实，两者生命周期不同。

## 收口

- 持久mapping恢复时登记symmetric verified-equivalence，不扫描backend。
- ArtifactCache lookup exact-first，miss后检查直接equivalent identities；因此晚到promote自然可见。
- 写入仍exact，不把equivalence当storage redirect；hard alias/rekey继续只属于既有显式能力。
- mapping后台刚完成时立即登记equivalence，当前活跃Reader后续尚未启动的页可直接受益。
- partial维持dev.210 durable inactive复制模型；不因full reuse问题扩大hot partial共享。
