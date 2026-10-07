# dev.213 根因审计：Session Partial、VibeVenera 与迟到 Full Takeover

## 输入

- `zic-debug-trace-2026-08-11T03-35-42.jsonl`
- 文件库只读参考：`vibevenera-master.zip`
- 唯一代码基线：dev.212完整包。

## Trace结论

压力样本共5392条事件，存在四个重叠Reader：371页、377页、371页、377页。版本mapping warm共18次/5个relation identity，单relation最多6次，说明dev.212 stale revalidation实现仍有缺口。

full verified-equivalence并非整体失效：样本中有7条 `sourceRead` 明确 `verifiedEquivalentReuse=true`。但最终artifact checksum揭示至少三组不同DownloadId实际下载出完全相同内容，其中两组最能说明剩余缺口：

- 11,736,930 bytes / checksum `bb91d15e`：旧侧full完成后，新侧从约7.17MiB durable partial恢复，随后正确从equivalent full的range继续，说明“durable partial + equivalent full”链有效。
- 17,572,068 bytes / checksum `61d36554`：旧侧约96.65s seal/promote并在约97.31s写入persistent cache；新版约101.47s已恢复3个version mappings/1125个等价页，约102.56s恢复6,062,080-byte partial，但约103.05s仍从origin Range继续并最终再次seal出同一checksum。该页没有命中已存在的full。

因此“同图重下”至少包含两类根因：

1. 已存在verified-equivalent边，但相关full在active origin开始后才出现；session不会重新open transport。
2. 最终内容相同，但该DownloadId没有被当前page mapping映射到真正对应的related page。session partial共享无法修复第2类。

## VibeVenera源码对比

`CacheManager.aliasImage()`保存逻辑image key alias；`PipelineController._downloadIdentity()`在获取DownloadSession前先解析alias。`ImageDownloader._loadingImages`、`joinLoadingComicImage()`和 `_PartialImageCache(cacheKey)`均使用解析后的同一cache key；`DownloadSessionRegistry`同样按 `DownloadIdentity` 取session。因此VibeVenera确实有跨版本共享in-flight/session partial的效果。

但ZIC每个 `PipelineReaderSession`目前拥有独立DownloadRegistry和SourcePool。直接照搬需要把DownloadSession变成跨Reader composition owner，并重新定义：两个viewport的priority合并、一个route退出是否可取消共享request、retention成本归属、partial writer生命周期、Ingress/decode source引用和异常传播。该成本不适合仅为压力切换测试直接引入。

## dev.213修复

- ArtifactCacheManager在完整artifact权威落盘后发布promotion事件，并暴露direct verified equivalents。
- 活跃PipelineReaderSession只对本地registry已存在的等价DownloadId触发 `refreshDownloadForLocalArtifact`。
- LiveCoordinator保留目标session committed prefix，仅取消/替换当前network attempt；下一次open优先消费equivalent full。
- cache-resident目标不重复takeover；本地full出现后清除旧network terminal/retry/defer记忆。
- 修复dev.212 stale mapping“页数相同就continue”的错误：fresh mapping可跳过；stale mapping必须重新strong verify，成功后用新的verifiedAt替换。
- origin trace增加 `verifiedEquivalentCandidates`，为下一轮区分mapping覆盖与artifact可用性。

## 暂不实现

跨Reader共享hot/session partial。保留dev.206单writer ownership和dev.210 durable inactive partial规则。只有后续正常使用而非极端压力切换仍频繁证明其收益大于生命周期复杂度时，再单独设计。
