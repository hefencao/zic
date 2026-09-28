# ADR 0336：Detached raster residency 与 identity / proof / authority / generation 分层

状态：Accepted

## Context

ADR 0335 后用户仍复现“部分图片无法加载，最后只能强制重新下载”。
fresh Profile trace `zic-debug-trace-2026-09-28T15-42-23.jsonl` 没有进入 ADR 0335 新增的任何显式 failure recovery：
`manual-force-reload=0`、`presentation-raster-generation-recovery=0`、
`presentation-artifact-recovery=0`、`taskFailed=0`。

相反，trace 直接暴露 ordinary detached-raster residency 生命周期断裂。例如
`identity:<6ed084a02a5fdb02,622>` 先完成 detached prepare 与 mounted visible first-frame，
随后因 raster budget 触发 `presentation-raster-cache-invalidated`；
约 3.04s 后同一个 presentation identity 再次收到 `mounted-presentation` request，
却不再产生 mounted first-frame。另两个 identity
`<0a8749b4e70b2fc7,622>`、`<-1a878f5fd12b74da,622>` 具有同样序列。

代码审计发现两个 UI-side ownership 泄漏：

1. `LocalImagePlayer._externalPresentationLoadIdentity` 把“本次 residency grant 已尝试”
   错当成整个 widget lifetime 的“该 presentation generation 已消费”。
   Cache eviction 正确保持 generation 不变，因此后续同 identity regrant 永久被该字段拦截。
2. detached cache 已返回 exact managed resident provider，但 mounted `MediaRasterImage`
   又对它执行 resize + `PipelinePresentationRasterCache.providerFor`。
   这会为同一个 presentation identity 制造嵌套 raster key，并在 detached→mounted handoff
   时偷偷移动 cache entry，而不是直接消费 cache owner 已准备好的 exact raster。

这说明问题不是“还需要一层 raster recovery”，而是 detached 与 mounted 没有共享同一个
residency authority。

## Ownership model

| 名称 | 所有层 | 语义 | 能否触发 destructive mutation |
| --- | --- | --- | --- |
| `DownloadId` | domain / logical source | exact provider/version/page identity | 否 |
| `PhysicalMediaId` | composition / download registry | 单一 encoded body / writer identity | 否 |
| checksum、length、`ArtifactReadIntegrityBasis` | storage/download proof | 已验证的内容事实；proof 不是 owner | 否 |
| `storageId + ArtifactCache mutation generation` | `ArtifactCacheManager` | 某次 exact read 的条件 mutation authority | 是，仅匹配原 generation 时 |
| `SourceEpoch` | `DownloadSession` / ingress | mutable physical source lifetime 的 stale-work fence | 是，限 source/session reset |
| `DecodeId` | domain / Pipeline | immutable download+target+renderer identity；不是计数器 | 否 |
| presentation cache identity | `PipelineReaderSession` | DecodeId/source/fit 的 opaque presentation generation | 否；只选择/退休 raster generation |
| raster claim/residency/LRU | `PipelinePresentationRasterCache` | decoded static raster 是否 resident、keepAlive 与预算 | 否 |
| `externalPresentationReady` | Pipeline scheduler | “该 exact presentation 曾完成一帧”的 satisfaction fact | 否；不是 byte proof/authority |
| `PipelinePageOutputStream._bindingEpoch` | page-output adapter | 取消旧 async present 的本地 binding epoch | 否 |
| `LocalImagePlayer._loadEpoch` | widget adapter | 取消旧 async load 的本地 race epoch | 否 |

“proof / authority / generation”因此不能互换：
proof 只说明观测到什么；authority 才能授权哪一种 mutation；generation/epoch 只在自己的
owner 内防止旧工作越过更新边界。

## Decision

1. `PipelinePresentationRasterCache` 是 external-static decoded raster 的唯一 residency owner。
   detached prewarm 与 mounted presentation 只能消费同一个 cache entry，不得各自形成隐式 cache。
2. ordinary cache eviction/clear/demand loss MUST keep presentation cache identity stable。
   Pipeline 清除 request/ready satisfaction 并等待同 identity staged regrant；不得把 residency loss
   解释为 source/artifact/presentation generation change。
3. `LocalImagePlayer` 的去重字段降级为“当前 residency grant attempt”：
   cache-owner revocation 时必须清除 attempt、取消旧 load、释放 file lease，并清理 UI 持有的
   bytes/provider；later same-identity grant 必须能够重新 attach/decode。
4. exact `_ResidentPresentationImageProvider` 已经是 cache owner 产生的最终 resized managed raster。
   mounted `MediaRasterImage` 必须直接 resolve 它，不得再次 resize 或 `providerFor`。
5. 删除 ADR 0335 新增的 authority-less automatic raster-generation recovery。
   无 exact artifact authority 的 presentation error 不再凭空旋转 presentation generation；
   exact artifact read rejection 仍可按原 `storageId + mutation generation` 条件进入
   `DownloadTransferOwner.recoverPresentationArtifact`。用户显式 force reload 保留为最终 fresh-source 命令。
6. 为减少同名“generation”误导：
   - widget-local `_generation` 重命名为 `_loadEpoch`；
   - page-output local `_generation` 重命名为 `_bindingEpoch`；
   - `externalPresentationReady` 文档称 scheduler satisfaction fact，不再称 content/raster authority proof。
7. 不扩大 7/3、2/1、NetLane、upload、presentation 或 raster budget。

## Device verification

final-source Profile `zic-debug-trace-2026-09-28T16-37-25.jsonl` 在同一漫画做多轮大跨度 slider scrub；共记录 193 次 raster-cache invalidation，仍为 `manual-force-reload=0`、`presentation-artifact-recovery=0`、`taskFailed=0`。

可直接和旧 trace 对照同一个 presentation identity `identity:<0a8749b4e70b2fc7,622>`：旧 trace 在 `2057496748` eviction 后 `2060573452` mounted re-request 再无 first-frame；新 trace 在 `612468906` eviction 后，同 identity 于 `614029184` mounted re-request，并在 `614053568` 产生 mounted first-frame（24.384ms）。最终停在 page indexes 36/37/38 约 7s，三页 host first-frame 均已完成，mount→first-frame 分别约 31.8/32.0/112.1ms。

这不是“所有 mounted request 都必须完成”的证明：高速 scrub 会正常取消已离开 viewport 的 request。验证点是 ordinary eviction 后同一 immutable presentation identity 在重新成为实际 mounted/visible consumer 时能够再次完成 first-frame，而不需要旋转 generation 或强制重下。

## Regression

`external_presentation_generation_test` 现在覆盖：

- detached prewarm 后 mounted handoff 不重新打开 encoded source；
- mounted 前后 resident cache key 完全相同，禁止 nested managed key；
- raster residency 被明确清空后，later same presentation identity regrant 能重新进入 encoded presentation；
- ordinary eviction/regrant 不旋转 presentation generation；
- widget 不再作为第二份 encoded/raster cache：真实 residency 消失后只通过 authoritative loader 重建。

既有 `presentation_raster_cache_test`、`external_static_prewarmer_test`、
Pipeline artifact-recovery / generation-guard tests继续验证各自 owner 边界。
