# ADR 0189：同源版本临时 Artifact Alias 与纵向 Anchor 所有权

状态：Accepted
版本：0.31.0-dev.207

## 背景

dev.206 之后仍有三类相互独立的问题：已确认同源新版时旧版 source card 可能没有更新 `!`；用户只“查看新版”而未执行迁移时，同一图片仍按新版 DownloadId重新下载；纵向静态Reader在页面比例异步收敛时会出现短距离回拉。

旧更新实现把 `sourceUpdateAt`绑定在“首次发现新 relation”瞬间。如果 relation先持久化、之后入架流程清过 signal，后续再次观察同一 relation不会恢复提醒。

Artifact复用方面，现有 `VerifiedArtifactReusePlan`只在真正迁移时注册 alias，因此“查看新版”没有复用机会。VibeVenera的有效边界不是复制缓存，而是确认版本关系/页面对应后把新版逻辑key临时映射到旧cache key。ZIC已经有 composition-owned `ArtifactCacheManager.alias`，不应复制另一套cache。

Reader方面，`ReaderView.didUpdateWidget`过去将每次 `pageAspectRatios` map变化都视为需要preserve top anchor，并在post-frame `jumpTo`。比例本身由异步图片几何收敛产生，这个修正与用户正在进行的scroll gesture竞争。

## 决策

1. Confirmed successor是持续 `ComicVersionRelationStore`事实，而非一次性事件。若旧版SavedComic缺少 `sourceUpdateAt`，重新观察持久relation或入架时必须可重建signal；没有confirmed relation的普通metadata/阅读/浏览仍不得产生版本更新。
2. 已确认同源版本在“查看新版”进入Reader前，可以准备**临时 artifact alias**，无需先迁移书架/阅读状态。
3. Alias owner仍唯一是 `ArtifactCacheManager`。App只构造经过验证的new DownloadId → old DownloadId关系；只对真实存在的旧artifact注册alias，不复制字节、不建立第二缓存、不修改durable library identity。
4. Venera等opaque page locator不得按页码/标题/URL token猜等价。复用identity通过现有 `ComicSourceResourceGateway → ExternalPluginResourceTransportPool → source-owned request plan`解析，不读取媒体body；只接受E-Hentai `/s/<image-key>/`或唯一32–64位内容hash等强identity。
5. 当manifest本身没有逐页强identity时，允许参考VibeVenera使用首/中/末resolved identity验证稳定offset：单页要求1/1，多页至少2/3一致，且仅在new page count不小于old时建立对应关系。该证据只在已有source-confirmed predecessor/successor relation内有效。
6. 新版精确artifact一旦真实写入，`ArtifactCacheManager`既有写入语义自动解除该new id的alias；真正迁移仍走既有comparison/rekey边界。
7. 纵向Reader不得因为 `pageAspectRatios` 异步变化保存/恢复top anchor。vertical stitch、真实viewport/DPR变化以及显式页面导航仍可使用既有anchor机制。

## 不做

- 不引入VibeVenera CacheManager或第二套key store。
- 不因标题相同、页码相同或URL token相似自动alias。
- 不为消除抖动删除旋转/viewport/stitch/显式导航所需anchor。
