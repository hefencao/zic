# ADR 0190：版本关系投影与双向 artifact alias

- 状态：Accepted
- 版本：dev.208
- Supersedes：ADR 0189 中“通过 `sourceUpdateAt` 重建版本提醒”以及“只做 new→old 临时 alias”的局部决策；ADR 0189 的纵向 ratio-anchor 决策继续有效。

## 背景

dev.207 把 source-confirmed predecessor/successor relation 持久化，并在 Reader 前用强媒体 identity 建立临时 artifact alias，但真机仍暴露两个结构性缺口：

1. source browser 的 `hasUpdate` 是同步 presentation 查询，只读取 Home 当前投影。relation 虽然已持久化，仍可能只存在 SQLite；若没有再次进入详情触发 `sourceUpdateAt` 修补，旧版卡无法看到 `!`。
2. artifact reuse 只查询“当前版本的 predecessor”，因此旧缓存→新版可以工作，新版缓存→旧版没有候选。版本先后关系被错误地当成 cache reuse 方向。

## 决策

### 1. confirmed relation 是 Home 的一等投影事实

`ComicVersionRelationStore` 增加 `listAllComicVersionRelations()`；`HomeLibrarySession` 在 enrichment 阶段一次加载全部 relation，并通过 `upsertVersionRelation()` write-through 同步后续新 relation。

source browser/Home presentation 同步读取 `HomeLibrarySession.versionRelations`。旧版存在 source-confirmed successor 即构成版本更新事实，不需要详情页先执行额外副作用。

### 2. 章节更新与版本更新不再互相写回

- `SavedComicRecord.sourceUpdateAt`：章节/目录/source revision 更新事实。
- `ComicVersionRelation.discoveredAt`：source-confirmed版本关系首次确认时间。

版本 relation 不再通过修改 `sourceUpdateAt` 来制造 signal。Home“更新漫画”把两类事实按 presentation 层合并并排序；阅读进度与普通 metadata 不参与。

SQLite 同一 relation 重复保存时保留首次 `discovered_us`，避免每次打开详情都把版本更新时间刷新成“现在”。

### 3. cache reuse 关系可双向，alias 图必须无环

source-confirmed predecessor/successor 只证明两个 raw version 属于同一版本链，不决定复用方向。打开任一版本时：

1. 同时查询当前版本的 predecessor 与 successor；
2. 找相关版本同序章节；
3. 用 checksum、来源 page key、内容 hash，或 source request-plan 解析后的强媒体 identity 验证直接对应/有界 offset；
4. 只有相关侧真实 artifact 已存在且当前 target 没有自己的真实 artifact时，才注册 `target DownloadId → source final storageId` 临时 alias；
5. 若 target 已经通过 alias解析到同一 storage，视为已复用而不再增加反向 alias；若 target已有真实artifact，不覆盖。

因此旧缓存→新版、新版缓存→旧版都可复用，但不能形成 `A→B→A` alias 环，也不复制字节、不改变 durable library identity。

## 后果

- 版本提醒不再受“是否先打开过详情页”影响。
- `sourceUpdateAt` 回归单一章节更新职责。
- cache reuse 不再错误绑定版本方向。
- Home enrichment 多一次 relation 全量读取；relation 表规模远小于章节/页面资源，且与既有 projection revision barrier 共用一致性边界。
- 强身份不足时仍正常 miss并走 origin；不得用页码/标题猜测建立 alias。
