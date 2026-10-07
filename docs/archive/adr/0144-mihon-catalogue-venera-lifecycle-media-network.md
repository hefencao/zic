# ADR 0144：Mihon CatalogueSource、Venera 生命周期与媒体网络边界

**状态：Accepted**

## 背景

dev.159 后设备仍出现 Roumanwu 目录从既有多章退化为空、禁漫天堂单章不可读、绅士漫画章节/页数存在但封面正文不可见，同时 Venera 插件会在设置/登录后掉线。对照用户提供的当前 Mihon 主仓后确认：ZIC 1.6 compatibility `CatalogueSource` 将 details 返回的新 SManga再次用于 `fetchChapterList`，与 Mihon 当前宿主不一致；共享外部 source settings/login又被错误绑定到 runtime replacement生命周期；共享媒体 transport还注入 Venera专用 UA，并可能把 2xx HTML/拦截页直接交给 decoder。生产 runtime进程默认8 session也会把测试安全默认变成用户可见插件数量上限。

## 决策

1. Mihon 1.6 `CatalogueSource.getMangaUpdate` compatibility shim必须与当前宿主一致：`fetchMangaDetails(manga)` 与 `fetchChapterList(manga)` 都以传入的原始 `SManga`为请求身份，可并行完成；不得把 detailed manga再传入 chapter-list。legacy fallback同样使用原始 manga。
2. payload安装/升级与 runtime settings/login分离。代码/payload替换继续使用 registry事务式 replacement；普通 source settings与Venera Web登录在当前 runtime原地完成。通用 restart API删除，只保留 Mihon browser handoff语义受限 restart；本 ADR不改变 Cloudflare状态机。
3. 生产 plugin runtime明确使用32个 active-session安全上限；generic plugin_host的8-session默认只服务测试/embedding，不得成为用户安装第9个插件后静默丢失的生产语义。
4. shared source transport不得设置Venera专用默认UA。Mihon `imageRequest(page)`/cover request plan继续保留source method/headers/body及当前Cookie/UA；若宿主HTTP成功但响应前缀不是已知编码图片，必须在字节进入Pipeline/decoder前拒绝，并使用已有source-owned runtime network兼容路径。正常可重放媒体继续走统一host streaming。
5. Mihon comic-details/chapter metadata提升schema revision，一次性绕过旧错误空/单目录durable manifest；不清除其它source artwork/catalog缓存。

## 非目标

- 本轮不修改Cloudflare classifier、WebView完成判定或clearance策略。
- 不按章节标题/URL/序号猜测禁漫天堂的单章节。
- 不新增Venera/Mihon私有图片缓存或第二套Downloader。
- 不把正常图片完整body常态化经JSON/Base64 RPC。

## 取代关系

本ADR部分取代ADR 0143中“settings/WebView restart与payload更新共用事务式replacement”的泛化描述；事务式replacement继续是代码/payload升级的正确owner。
