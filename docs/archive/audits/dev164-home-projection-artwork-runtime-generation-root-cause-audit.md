# dev.164 Home projection、Artwork namespace 与 Runtime generation 根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.163_venera-activation-history-cover-state.zip`
- 设备 trace：`zic-debug-trace-2026-08-08T05-55-30.jsonl`
- 用户现象：Reader 退出后首页阅读历史不更新；漫画源页封面可见而详情/阅读历史不可见；dev.163 Venera activation恢复被判断为补丁式处理。

## Trace 事实

- 本次 trace 有 60 次 `homeCoverRequested`、53 次 `homeCoverSourceReady`、46 次 `homeCoverFirstFrame`、7 次 `homeCoverSourceFailed` 与 1 次 `homeCoverDecodeFailed`。
- `mihon:6551136894818591762` / `https://www.wn09.shop/photos-index-aid-375115.html#` 第一次 history cover失败时 `sourceAvailable=false`；source ready后同一 history owner继续多次以 `Failure` 失败，说明 dev.163 已把“插件尚未 ready”与“source 已可用但资源仍失败”区分开，不能继续用 source-ready retry解释全部封面问题。
- trace 无 progress durability/barrier错误事件，现有代码审计显示 Reader history不更新来自 durable store与 Home projection的双状态窗口，而不是 SQLite必须完成后才能退出。

## 代码根因

### A. Home projection 落后 durable store

`_ensureSourceChapter`、详情刷新和迁移等路径直接 `_library.upsertChapter/upsertSavedComic`。Home UI却只消费 `HomeLibrarySession.entries/savedComics`。新 source chapter写入 durable store后可以立即进入 Reader，但 session内存投影尚无该 chapter；Reader route 返回调用 `replaceProgress` 时无法匹配 entry。进入/退出详情触发 `_reloadLibrary()` 后才补齐，因此产生“必须再次进入详情页才更新”的表象。

同时 dev.163 用 `_latestReaderProgress` 保存所有 route 的最后 progress，它是 composition-wide mutable slot，不属于某个 Reader route。

进一步审查发现 `HomeLibrarySession.reload()` 还会在开始阶段捕获 entries/saved snapshot，完成 enrichment 后再次无条件写回；若 write-through 更新发生在这段窗口，旧 snapshot 可覆盖新 history projection。因此仅把写入改成 session API仍不完整，session还必须拒绝 stale reload snapshot覆盖更晚的 projection revision。

### B. External artwork 被拆成两个 revision namespace

`ComicSourceResourceGateway._artworkRevision` 默认生成 `artwork-v2`。漫画源 browse 调用 gateway默认 revision，因此写入 `artwork-v2`。

Home/详情 `_loadCoverSource` 却显式传入 `comicArtworkCacheRevision == artwork-v2`，gateway再拼接基础 revision，得到 `artwork-v2:artwork-v2`。所以 browse中已经成功的封面不会被 details/history命中；后两者 cache miss后重新进入 live source/network，恰好暴露来源失败。

这不是封面 URL或 canonical identity再次漂移，而是 revision owner重复。

### C. dev.163 activation恢复层级过高

dev.163 的 `_activatePlatformRuntime` 捕获 `PlatformException(runtime-service-died/disconnected)` 后重新发出 MethodChannel activation。它把 Android Binder generation loss表达成“插件激活再调用一次”，因此属于症状修补。

真正知道 binding generation、pending request与 service death 的 owner 是 `PluginRuntimeServiceClient`。

## dev.164 收口

- `HomeLibrarySession` 新增 chapter/SavedComic write-through mutation；相关 App composition路径不再直接 durable mutation后等待全量 reload。
- Reader final progress改为 route-local `latestProgress`，page callbacks仍只 enqueue，route返回只发布一次内存投影。
- `replaceProgress` 按稳定 chapter identity `sourceId + chapterId` 匹配。
- `comicArtworkCacheSchemaRevision` 归 `resource_cache`；external gateway参数改为 `contentRevision`，Home/details/history不再传基础 schema revision。
- 删除 Dart initial activation service-loss重放；Android Binder client保留 pending activation跨一个死亡/断开的 service generation，策略抽为纯 Kotlin `RuntimeServiceRequestLifecyclePolicy`。
- 不增加 cache copy/fallback、presentation retry、全量 history reload或 generic plugin restart。
