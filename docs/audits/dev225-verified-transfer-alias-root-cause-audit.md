# dev.225 Verified transfer alias root-cause audit

## 结论

dev.224后physical owner已覆盖Reader/prefetch/chapter/whole-comic，剩余重复owner主要来自“已验证等价页仍按不同DownloadId在acquire时各建session”。现有verified equivalence不是弱页码匹配：其来源是source-confirmed related versions，并由manifest checksum、E-Hentai image key、resolved URI content hash或已持久化verified offset mapping建立。因此可作为acquire-time join proof，但不应直接改写exact cache/offline identity。

## 安全切面

本轮只允许new exact identity加入existing physical session。若exact session已存在则不merge；若direct equivalence指向多个不同existing physical owners则不选择；source-resident且非cache authority没有独立encoded body，拒绝跨版本join。这样不需要迁移writer/artifact文件，也不需要伪造跨版本validator一致性。

## owner变化

- `DownloadRegistry`：新增runtime-local physical alias与exact-session probe；proof选择仍在downloads composition层。
- `CompositionDownloadTransferRuntime`：acquire-time verified candidate resolver。
- `DownloadTransferOwner`：claim从exact demand归一到physical demand，同时保存provider exact identity；查询路径只解析已建立alias，不得触发新alias。
- chapter command：先claim acquire，再读取session；exact durable completion保持exact。

## 兼容路径

`VerifiedArtifactReusePlan`、persisted mapping、ArtifactCacheManager equivalence继续保留并成为proof source。late equivalent-full takeover与session/durable partial handoff仍覆盖双session/cold partial/拒绝join路径，本轮不删除。
