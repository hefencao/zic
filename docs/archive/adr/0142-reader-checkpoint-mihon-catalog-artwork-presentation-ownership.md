# ADR 0142：Reader checkpoint、Mihon 目录与 artwork presentation 所有权收口

## 状态

已接受。取代 ADR 0141 中“Reader 返回等待 durable barrier并全量刷新历史”的实现细节；取代 ADR 0127–0130/0141 中仍允许 presentation 自动封面恢复、first-frame watchdog、短时 source Future join的当前态描述；Mihon章节方面取代“combined update 与显式 chapterList 可互换并由结果数量猜权威”的实现。历史 ADR 保留证据，不再作为当前生产合同。

## 触发证据

真机 dev.156 同时出现三类回归：Reader/全 App卡顿没有消失；原本可加载多章节的来源退化为空或无效单章节；已成功显示的封面仍会再次重新加载。逆向调用图显示这些现象都来自多个 owner/时序平面仍在竞争，而不是缺少更多重试。

## 决策一：Reader checkpoint 不等于 durable commit

Reader 页面变化只向 `ReaderProgressCheckpointStore` 入队最新 `ReadingProgress`。storage-owned isolate 对同一 source/chapter latest-wins 合并：空闲约 8 秒提交一次，持续活跃最多约 30 秒提交一次；SQLite/WAL 不属于 Reader route完成条件。显式 `saveProgress()` 和 store close仍可等待内部 durability barrier。

Reader route 返回后，Home只把该 route 最终 progress更新到匹配的内存 projection一次；已打开详情页只替换当前章节 progress。不得在 Reader 返回路径 `reloadLibrary` 或扫描整库。异常硬终止最多可能丢失最后一个 batching窗口，属于 best-effort，不宣称 crash-safe。

## 决策二：Mihon chapter catalog 只有一个能力顺序

1. 优先调用明确的 `getChapterList` / `fetchChapterList`；成功结果（包括空）就是权威。
2. 明确 chapter-list 能力不存在时，才调用 TachiyomiX 1.6 `getMangaUpdate` / `fetchMangaUpdate` 一次，并按原顺序传入已知章节。
3. chapter-list 的真实网络/解析错误直接失败，不再换 combined API掩盖错误。
4. 不从 manga URL生成 synthetic `SChapter`，不按“开始阅读/正文”等显示文字增删章节。
5. 完全相同且非空的 `SChapter.url` 是同一 source-side page-list locator，可折叠为一个条目；元数据更完整者优先，完全平分时后出现者优先。不同 URL不得按标题、number或 sequence推断为同一章节。

raw chapter/model消息仍服务 plugin runtime locator；目录 normalize 不创建第二套 App chapter identity。

## 决策三：artwork presentation 不拥有恢复策略

`ComicSourceResourceGateway/ResourceCacheManager` 是外部 artwork 字节和 durable response缓存的唯一 owner。Home、书架、漫画源、详情 presentation只消费一个 Future/ImageProvider并显示成功或稳定占位。删除：

- `ArtworkRetryController` / `RecoverableArtworkImage`；
- presentation timer retry；
- first-frame watchdog；
- App lifecycle 自动 retry；
- presentation 对 Flutter 全局 `ImageCache.evict()`；
- App级 `_coverSourceInflight` 短时 Future join；
- decoder failure后由 UI强制刷新 encoded bytes。

显式来源刷新、资源 revision 或稳定 identity真实变化才允许重新请求。

Mihon raw `comicId` 继续只是可变 runtime locator；durable artwork key和 Home/书架/详情 presentation key都使用 canonical comic identity。封面 URL、resume chapter、loader closure或 raw alias变化不得销毁已经成功的封面 State。`mihon:resource:` 等插件 URI与 HTTP(S)一样只走统一 gateway，不得回落到本地文件 loader。

## 验证要求

- 长会话统计 SQLite progress事务次数，不得每页提交；Reader pop动画不得等待 durable write。
- 真实 Mihon 1.4/1.6来源验证明确 chapterList 与 combined-only两类能力；禁止一次刷新重复请求两套目录。
- 同一漫画在 browse/details/history 改变 raw SManga快照后，canonical artwork/presentation identity保持不变。
- 成功封面在普通 parent rebuild、resume、decode stream稳定后不得由 presentation自动重载；失败封面只有显式刷新才重试。
