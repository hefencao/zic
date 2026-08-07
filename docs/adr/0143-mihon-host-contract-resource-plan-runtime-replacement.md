# ADR 0143：Mihon宿主合同、资源Request Plan与Runtime事务替换

**状态：Accepted**

## 背景

dev.158真机同时出现：禁漫天堂目录只剩一个不可读章节；Roumanwu此前80章刷新为0章；绅士漫画能得到章节/页数但封面和正文图片不可读；Mihon插件仍会在重启/验证附近消失。用户同时提供当前 Mihon主仓与两份Trace。接口对照确认 dev.157 对 Mihon `Source` 合同做了错误逆向：当前宿主统一调用 `getMangaUpdate`/`getPageList`，`CatalogueSource`自己向后兼容 legacy Observable API；ZIC却优先反射不存在于当前 `Source`接口的 `getChapterList`/deprecated `fetchChapterList`。dev.157还把相同 `SChapter.url` 当成宿主可去重 identity，但 `getPageList`接收完整 `SChapter`，该假设不成立。

另一方面，ZIC从 page只提取最终 URL/headers并硬编码 GET；Mihon `HttpSource.imageRequest(page)`允许来源覆盖 method、headers乃至POST。真正的 `source.client`请求还会由 CookieJar/interceptor补会话上下文。已激活插件的 restart/update则存在 deactivate-first路径，候选激活失败会制造插件瞬时或持续消失。

## 决策

1. TachiyomiX 1.6/current Mihon目录主入口为 `Source.getMangaUpdate(manga, existingChapters, fetchDetails, fetchChapters)`；成功输出（含空列表）权威。`CatalogueSource`已在内部调用 legacy `fetchMangaDetails/fetchChapterList`。ZIC仅在 combined能力明确不存在时为1.4兼容调用 legacy；真实解析/网络错误不得跨接口隐藏。
2. 正文主入口为 `getPageList(SChapter)`；成功空列表权威，只在能力明确缺失时回退 `fetchPageList`。目录阶段不预取页面来猜章节可读性。
3. `SChapter`为 source-owned完整输入。ZIC不按 title、url、number、sequence或其它局部字段去重/推断；尤其相同URL不表示 `getPageList`语义相同。driver内部 live chapter cache按 sourceId + comic/chapter identity作用域隔离，但不改变持久wire chapterId。
4. Mihon图片资源从 `imageRequest(page)`（封面从source headers/request语义）形成完整 request plan：URL、method、headers与必要的小型request body全部保留。GET/HEAD无body。host streaming解析plan时同步加入当前 source client CookieJar Cookie与 browser-session UA。扩展自定义、source-owned interceptor/response transform无法在宿主重放时继续使用既有 `requiresRuntimeTransform`兼容能力；普通图片body仍由宿主transport进入统一Pipeline。
5. 同pluginId restart/update采用事务替换：候选 runtime先完整activate并通过 source identity/collision等验证；成功后原子替换registry owner，再关闭旧session。候选失败保留旧session。controller安装更新不得先deactivate。
6. 详情Presentation不得把“成功空章节目录”改写为Cloudflare验证。只有typed `sourceVerificationRequired`可进入WebView恢复。

## 取代

本ADR取代ADR 0142中“explicit `get/fetchChapterList`优先”和“相同非空 `SChapter.url`可折叠”的Mihon生产规则；ADR 0142的Reader checkpoint和artwork Presentation所有权部分继续有效。
