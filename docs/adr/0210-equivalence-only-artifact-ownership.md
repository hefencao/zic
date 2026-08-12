# ADR 0210：Equivalence-only artifact ownership

- 状态：Accepted
- 日期：2026-08-12
- 版本：dev.230

## 背景

dev.211起版本full artifact读取已使用symmetric verified equivalence，dev.225起相同proof又用于physical acquire alias，dev.229进一步把cold partial复用迁到physical prepare。23:45 dev.229真机Trace中`version-durable-partial-reused`已归零、equivalent cold restore真实命中，说明directed hard artifact alias/rekey只剩显式迁移`applyExisting()`与历史API。

Hard alias会把一个exact DownloadId的durable lookup重定向到另一exact storage identity，与当前“exact identity是write/offline authority，equivalence只是proof/fallback”的模型冲突；同时普通Reader命中equivalent durable body后再materialize一份exact artifact也制造无必要副本。

## 决策

1. `ArtifactCacheManager`删除directed `_aliases`、`resolveAlias/alias/removeAlias/rekey`及alias容量；只保留bounded direct symmetric equivalence。
2. `VerifiedArtifactReusePlan`只产生verified `mappings`并注册equivalence；删除`apply/applyExisting/rekeyExisting`。
3. 显式漫画源迁移对强identity匹配页只登记equivalence，不再按“当前source artifact是否存在”创建hard alias快照。
4. exact DownloadId始终是durable write authority；`lookupAuthoritative/containsBackendExact`永远只访问exact backend key。
5. ordinary Reader promotion若exact durable miss但direct verified-equivalent durable artifact已存在且长度一致，handoff记录`skip-verified-equivalent-durable`并不复制exact body。
6. required offline completion仍可materialize exact durable identity；等价读复用不得伪造command completion。
7. 本轮不改变live physical alias、cold partial restore、NetLane、retry、Reader decode/upload/presentation。

## 后果

cache identity不再存在“hard alias storage redirect”和“verified equivalence lookup”两套重叠机制。后续重复exact artifact只能来自显式exact completion或proof未恢复，能够用handoff trace直接审计，而不能再靠alias隐藏。
