# ADR 0192：Verified artifact equivalence 与迟到 promote 复用

状态：Accepted
版本：0.31.0-dev.211

## 问题

dev.210 已把昂贵 page identity验证移出Reader关键路径并持久化 chapter offset mapping，但 full artifact恢复仍使用 `VerifiedArtifactReusePlan.applyExisting()`：进入Reader时逐页检查相关版本是否**当下已经**有promoted artifact，只有命中的页才注册 directed alias。

02:00真机trace证明 mapping并未缺失：再次进入371页旧版前记录 `persistentMappings=3`，但只 `reusedPages=13`；与此同时377页相关版本仍持续下载并在之后才promote更多artifact。这些迟到artifact不会触发第二次 `applyExisting()`，所以旧版后续仍可能走origin。VibeVenera的临时image-key mapping本质上是逻辑key关系，读取时再解析；ZIC需要保留这一语义，同时避免directed双向alias环和跨版本写入重定向。

## 决策

1. `ArtifactCacheManager`新增有界 symmetric verified-equivalence graph。关系必须由外部已验证page mapping提供；CacheManager不推断版本/页等价。
2. equivalence只参与lookup fallback。每个请求先查自身hard-alias解析后的exact storage；exact miss后才按直接equivalent DownloadId逐一查memory/persistent artifact。equivalence不递归推导未直接验证的版本链。
3. equivalence登记不要求任一侧artifact当前存在。相关版本未来才promote immutable artifact后，另一版本的后续lookup即可命中。
4. 所有写入仍使用调用方exact DownloadId。`storePromotedArtifact/remember`不把equivalence改成storage redirect；目标自身artifact一旦存在，exact-first天然优先。显式迁移使用的hard `alias/rekey`语义保持独立。
5. `VerifiedArtifactReusePlan.registerEquivalences()`把持久offset生成的页对称登记。Reader前只做O(page)内存登记，不扫描backend；后台mapping刚验证完成时也立即登记，使当前活跃Reader的未来demand可见。
6. Trace的cache hit增加 `verifiedEquivalentReuse`；Reader restore事件改为 `version-artifact-equivalence-restored`，记录mapping数与equivalent page pair数，不再把一次性backend扫描数称为`reusedPages`。
7. partial不进入equivalence graph。partial仍按ADR0191只复制durable inactive prefix并清空跨版本validator；hot DownloadSession禁止共享。

## 结果

版本mapping与artifact存在时序解耦。一次确认的page equivalence可覆盖“另一版本稍后才下载完成”的场景，而exact artifact、写入identity、partial/session ownership和显式migration alias都保持原有边界。
