# dev.167 漫画源封面与筛选根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.166_retained-artwork-cache-ownership.zip`。
- 设备 trace：`zic-debug-trace-2026-08-08T09-45-09.jsonl`。
- 用户现象：刚打开详情后返回漫画源页，已正常显示的封面会很快失效；来源筛选入口不可见，要求调整为“最新 | 热门 | 筛选”。

## Trace 事实

- Mihon popular browse 完成后，多个 details refresh紧接完成；随后 latest browse又产生新的 changed projection。
- 后续同一 source存在 cache-hit background refresh，也存在 latest/popular普通 refresh；因此 browse projection变化与详情生命周期确实会在同一页面会话中交错。
- 当前 trace没有 source-card per-cover first-frame/decode事件，因此不能仅凭设备日志把失效归因于 durable cache删除或某一次 decoder error。

## 代码根因

1. `_applyBrowsePage()` 每次更新全局 `_contentRevision`，所有 `_RemoteImage.reloadToken`都包含该值。任一 browse page/SWR变化都会强制所有封面重新 `_load()`，把 metadata projection错误提升成 artwork revision。
2. source grid的 Sliver direct child用 raw `comicId` 做 key；raw插件 locator允许随详情补全/alias变化，不能拥有 Presentation State。
3. filter capability与 runtime传参已经实现，但 chips只在展开 floating search后出现；它既不是 source category，也不应被藏成搜索 suggestion。

## 修复

- 删除 `_contentRevision` 与其 artwork reload关系；source-card只接受显式 `_artworkRetryRevision`。
- direct-child key改为 `sourceId + canonical comic identity`；raw key下沉到卡片交互节点。
- 增加 source-cover分层 trace，canonical identity用于关联 load/source-ready/first-frame/failure。
- source section按 latest、popular优先排序；filter作为分类栏末尾 ActionChip打开 modal filter panel。
- filter panel继续操作唯一 `_selectedFilterIds`，请求仍进入 `FilterableBrowsableComicSource.browseWithFilters`；floating search不再建立第二套 filter UI。

## 非修复项

- 没有增加 cover retry、provider eviction、第二 image cache或 cache copy。
- 没有把 plugin filter伪装成 `SourceBrowseSection`。
- 没有修改 Mihon Cloudflare、Venera runtime lifecycle或 Reader/Pipeline策略。
