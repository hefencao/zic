# dev.208 版本提醒与反向 artifact reuse 根因审计

## 用户现象

- dev.207 后旧版漫画源卡右上更新感叹号仍缺失。
- 新版本已有缓存时再打开旧版本，同图不能复用并重新下载。

## 新 trace 证据

用户提供 `zic-debug-trace-2026-08-11T00-01-28.jsonl`。

审计确认 trace 中存在一次 dev.207 reuse 准备：

- `stage=version-artifact-alias-prepared`
- `relationCount=1`
- `candidateChapters=1`
- `reusedPages=40`

这证明 dev.207 的旧缓存→新版 alias 不是完全失效，而是至少一条方向实际成功。

后续又创建了一个 371 页 Reader session，但其前后没有第二次 `version-artifact-alias-prepared`。结合源码 `_prepareSourceVersionArtifactReuse()` 只调用 `listComicVersionPredecessors(current)`，可确定 dev.207 没有“当前是 predecessor、缓存位于 successor”这条候选发现路径。

## `!` 缺失的代码根因

dev.207 中 `ComicVersionRelationStore` 可以已经持久化 confirmed successor，但 source browser 的 `_sourceComicHasUpdate()` 是同步调用，只看 Home 当前 `SavedComicRecord.sourceUpdateAt`。relation 本身没有进入 `HomeLibrarySession` 投影。

因此存在合法状态：

```text
SQLite: confirmed predecessor -> successor relation exists
Home SavedComic: sourceUpdateAt == null
source browser synchronous hasUpdate: false
```

dev.207 试图在详情/版本发现时调用 reconcile 再写 `sourceUpdateAt`，仍然属于跨 owner 副作用，并不能保证 source browser 初次显示时执行。

## 修复

- relation store增加 all-relations读取；Home session加载并write-through投影 relation。
- source card与Home update直接读取 projected confirmed successor；版本关系不再镜像到 `sourceUpdateAt`。
- relation增加首次 `discoveredAt`用于版本更新时间；重复确认不刷新时间。
- Reader artifact reuse同时查询 predecessor/successor；match函数以“已有artifact侧→当前target侧”命名/计算，不以版本新旧决定方向。
- `applyExisting`先解析 source最终storage与target当前alias，避免双向浏览后生成alias环。

## 明确未做

- 没有新增 cache owner。
- 没有复制 artifact 字节。
- 没有用标题、作者、相同页码建立版本/页面等价。
- 没有把版本关系重新写进章节 `sourceUpdateAt`。
- 没有修改 Venera/Mihon transport、Reader调度、水位或纵向anchor策略。
